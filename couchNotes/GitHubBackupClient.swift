//
//  GitHubBackupClient.swift
//  couchNotes
//
//  GitHub Git Data API で、md ファイル群を1コミットとして push する（git ライブラリ不要）。
//  全件スナップショット：base_tree を使わず、対象ファイルだけのツリーを作ってコミット＝
//  リポジトリ内容を「選んだフォルダのミラー」に上書きする（削除も反映、一方向）。
//

import Foundation

struct GitHubBackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitHubBackupClient {
    let owner: String
    let repo: String
    let branch: String
    let token: String

    /// md ファイル群を push する。progress は 0...1。
    func backup(files: [(path: String, content: String)],
                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !files.isEmpty else {
            throw GitHubBackupError(message: "バックアップ対象のノートがありません。")
        }

        // 1) 現在の HEAD（無ければ空リポジトリ＝親なし）
        let head = try await currentHead()

        // 2) ツリー作成（100件ずつ inline content・base_tree 連鎖で1本に積む）
        var treeSha: String? = nil
        let batchSize = 100
        var index = 0
        let total = max(files.count, 1)
        while index < files.count {
            let end   = min(index + batchSize, files.count)
            let batch = Array(files[index..<end])
            treeSha   = try await createTree(base: treeSha, files: batch)
            index = end
            progress(Double(index) / Double(total))
        }
        guard let finalTree = treeSha else {
            throw GitHubBackupError(message: "ツリーの作成に失敗しました。")
        }

        // 3) コミット
        let commitSha = try await createCommit(
            message: "Backup \(Self.timestamp())",
            tree: finalTree,
            parents: head.sha.map { [$0] } ?? []
        )

        // 4) ブランチ更新（無ければ作成）
        if head.exists {
            try await updateRef(sha: commitSha)
        } else {
            try await createRef(sha: commitSha)
        }
    }

    // MARK: - API 呼び出し

    private func currentHead() async throws -> (sha: String?, exists: Bool) {
        let (data, code) = try await request("GET", "git/ref/heads/\(branch)")
        if code == 404 { return (nil, false) }
        guard code == 200 else { throw error(data, code) }
        let sha = ((json(data)?["object"] as? [String: Any])?["sha"] as? String)
        return (sha, true)
    }

    private func createTree(base: String?, files: [(path: String, content: String)]) async throws -> String {
        let entries: [[String: Any]] = files.map {
            ["path": $0.path, "mode": "100644", "type": "blob", "content": $0.content]
        }
        var body: [String: Any] = ["tree": entries]
        if let base { body["base_tree"] = base }
        let (data, code) = try await request("POST", "git/trees", body: body)
        guard code == 201, let sha = json(data)?["sha"] as? String else { throw error(data, code) }
        return sha
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
