//
//  GitHubBackupClient.swift
//  couchNotes
//
//  GitHub Git Data API で、md ファイル群を1コミットとして push する（git ライブラリ不要）。
//  全件スナップショット：base_tree を使わず、対象ファイルだけのツリーを作ってコミット＝
//  リポジトリ内容を「選んだフォルダのミラー」に上書きする（削除も反映、一方向）。
//

import Foundation
import CryptoKit

struct GitHubBackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitHubBackupClient {
    let owner: String
    let repo: String
    let branch: String
    let token: String

    /// md ファイル群を push する。リポジトリの現状と比較して差分だけ送る。
    /// 戻り値＝変更したファイル数（0＝変更なしでコミットせず）。progress は 0...1。
    @discardableResult
    func backup(files: [(path: String, content: String)],
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let head = try await currentHead()

        var entries: [[String: Any]] = []
        var baseTree: String? = nil

        if head.exists, let headSha = head.sha,
           let baseTreeSha = try await commitTreeSha(headSha),
           let repoBlobs = try await treeBlobs(baseTreeSha) {
            // 差分モード：git blob SHA を突き合わせ、変更・追加・削除だけ送る
            baseTree = baseTreeSha
            var currentPaths = Set<String>()
            for f in files {
                currentPaths.insert(f.path)
                if repoBlobs[f.path] != Self.gitBlobSHA(f.content) {
                    entries.append(["path": f.path, "mode": "100644", "type": "blob", "content": f.content])
                }
            }
            for path in repoBlobs.keys where !currentPaths.contains(path) {
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
            }
            if entries.isEmpty { return 0 }   // 変更なし
        } else {
            // 全件スナップショット（空リポジトリ／ツリー取得不可時のフォールバック）
            guard !files.isEmpty else {
                throw GitHubBackupError(message: "バックアップ対象のノートがありません。")
            }
            entries = files.map { ["path": $0.path, "mode": "100644", "type": "blob", "content": $0.content] }
        }

        // ツリー作成（100件ずつ base_tree 連鎖）
        var treeSha = baseTree
        let batchSize = 100
        var index = 0
        let total = max(entries.count, 1)
        while index < entries.count {
            let end = min(index + batchSize, entries.count)
            treeSha = try await createTree(base: treeSha, entries: Array(entries[index..<end]))
            index = end
            progress(Double(index) / Double(total))
        }
        guard let finalTree = treeSha else {
            throw GitHubBackupError(message: "ツリーの作成に失敗しました。")
        }

        let commitSha = try await createCommit(
            message: "Backup \(Self.timestamp())",
            tree: finalTree,
            parents: head.sha.map { [$0] } ?? []
        )
        if head.exists {
            try await updateRef(sha: commitSha)
        } else {
            try await createRef(sha: commitSha)
        }
        return entries.count
    }

    /// git のオブジェクトSHA（blob）を計算：sha1("blob <len>\0" + bytes)
    private static func gitBlobSHA(_ content: String) -> String {
        let bytes = Array(content.utf8)
        var data = Data("blob \(bytes.count)\u{0}".utf8)
        data.append(contentsOf: bytes)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - API 呼び出し

    private func currentHead() async throws -> (sha: String?, exists: Bool) {
        let (data, code) = try await request("GET", "git/ref/heads/\(branch)")
        if code == 404 { return (nil, false) }
        guard code == 200 else { throw error(data, code) }
        let sha = ((json(data)?["object"] as? [String: Any])?["sha"] as? String)
        return (sha, true)
    }

    private func createTree(base: String?, entries: [[String: Any]]) async throws -> String {
        var body: [String: Any] = ["tree": entries]
        if let base { body["base_tree"] = base }
        let (data, code) = try await request("POST", "git/trees", body: body)
        guard code == 201, let sha = json(data)?["sha"] as? String else { throw error(data, code) }
        return sha
    }

    /// コミットのツリーSHAを取得。
    private func commitTreeSha(_ commitSha: String) async throws -> String? {
        let (data, code) = try await request("GET", "git/commits/\(commitSha)")
        guard code == 200 else { return nil }
        return (json(data)?["tree"] as? [String: Any])?["sha"] as? String
    }

    /// ツリーを再帰取得し、path→blobSHA を返す。truncated（巨大）の場合は nil。
    private func treeBlobs(_ treeSha: String) async throws -> [String: String]? {
        let (data, code) = try await request("GET", "git/trees/\(treeSha)?recursive=1")
        guard code == 200, let obj = json(data) else { return nil }
        if (obj["truncated"] as? Bool) == true { return nil }
        guard let tree = obj["tree"] as? [[String: Any]] else { return nil }
        var map: [String: String] = [:]
        for entry in tree where (entry["type"] as? String) == "blob" {
            if let path = entry["path"] as? String, let sha = entry["sha"] as? String {
                map[path] = sha
            }
        }
        return map
    }

    private func createCommit(message: String, tree: String, parents: [String]) async throws -> String {
        let body: [String: Any] = ["message": message, "tree": tree, "parents": parents]
        let (data, code) = try await request("POST", "git/commits", body: body)
        guard code == 201, let sha = json(data)?["sha"] as? String else { throw error(data, code) }
        return sha
    }

    private func updateRef(sha: String) async throws {
        let (data, code) = try await request("PATCH", "git/refs/heads/\(branch)",
                                             body: ["sha": sha, "force": true])
        guard code == 200 else { throw error(data, code) }
    }

    private func createRef(sha: String) async throws {
        let (data, code) = try await request("POST", "git/refs",
                                             body: ["ref": "refs/heads/\(branch)", "sha": sha])
        guard code == 201 else { throw error(data, code) }
    }

    // MARK: - 下回り

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/\(path)") else {
            throw GitHubBackupError(message: "URL が不正です。")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("couchNotes", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func error(_ data: Data, _ code: Int) -> GitHubBackupError {
        let msg = (json(data)?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? "")
        return GitHubBackupError(message: "GitHub エラー (\(code)): \(msg)")
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}
