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

        if head.exists, let headSha = head.sha, let baseTreeSha = try await commitTreeSha(headSha) {
            // 既存コミットあり：base_tree の上に変更を載せる（非mdファイルは常に保持）
            baseTree = baseTreeSha
            if let repoBlobs = try await treeBlobs(baseTreeSha) {
                // 差分：git blob SHA を突き合わせ、変更・追加（content）＋ 削除は .md のみ
                var currentPaths = Set<String>()
                for f in files {
                    currentPaths.insert(f.path)
                    if repoBlobs[f.path] != Self.gitBlobSHA(f.content) {
                        entries.append(["path": f.path, "mode": "100644", "type": "blob", "content": f.content])
                    }
                }
                for path in repoBlobs.keys where path.hasSuffix(".md") && !currentPaths.contains(path) {
                    entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
                }
                if entries.isEmpty { return 0 }   // 変更なし
            } else {
                // ツリー取得不可（巨大で truncated 等）：削除はせず、全ノートを base_tree に上書き
                guard !files.isEmpty else { return 0 }
                entries = files.map { ["path": $0.path, "mode": "100644", "type": "blob", "content": $0.content] }
            }
        } else {
            // 空リポジトリ：ノートのみのスナップショット
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

    // MARK: - コミット履歴（タイムマシン）

    /// バックアップの1コミット＝「ある時点の状態」。
    struct BackupCommit: Identifiable {
        let sha: String
        let message: String
        let date: Date
        var id: String { sha }
    }

    /// ブランチのコミット履歴を新しい順に取得する（各コミットが復元可能な過去のスナップショット）。
    func listCommits(limit: Int = 50) async throws -> [BackupCommit] {
        let (data, code) = try await request("GET", "commits?sha=\(branch)&per_page=\(limit)")
        guard code == 200 else { throw error(data, code) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubBackupError(message: "コミット履歴の取得に失敗しました。")
        }
        let iso = ISO8601DateFormatter()
        return arr.compactMap { item in
            guard let sha = item["sha"] as? String,
                  let commit = item["commit"] as? [String: Any] else { return nil }
            let message = (commit["message"] as? String) ?? ""
            let dateStr = ((commit["committer"] as? [String: Any])?["date"] as? String) ?? ""
            let date = iso.date(from: dateStr) ?? .distantPast
            return BackupCommit(sha: sha, message: message, date: date)
        }
    }

    // MARK: - 復元（pull）

    /// リポジトリの全 .md ファイルを取得して (path, content) で返す（一方向の復元用）。
    /// `ref` に commit SHA を渡すとその時点の状態を取得（タイムマシン）。nil ならブランチ先端。
    /// まず tarball を1リクエストで取得・展開する（4000件規模でも軽い）。失敗時は GraphQL 経路へ退避。
    /// progress は 0...1。
    func filesForRestore(ref: String? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> [(path: String, content: String)] {
        let r = ref ?? branch
        do {
            return try await filesFromTarball(ref: r, progress: progress)
        } catch {
            // tarball のダウンロード・展開に失敗したら従来の GraphQL 経路で復元を試みる
            return try await filesFromGraphQL(ref: r, progress: progress)
        }
    }

    /// tarball（GET /repos/{owner}/{repo}/tarball/{ref}）を取得し、ローカルで .md を取り出す。
    private func filesFromTarball(ref: String,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> [(path: String, content: String)] {
        progress(0)
        let data = try await downloadTarball(ref: ref)
        progress(0.7)   // ダウンロードが大半。展開・抽出はローカルで速い
        let entries = try TarGzReader.entries(from: data)

        var result: [(path: String, content: String)] = []
        for (rawPath, bytes) in entries {
            // tarball のパスは "owner-repo-<sha>/相対パス"。先頭1階層を剥がす
            guard let slash = rawPath.firstIndex(of: "/") else { continue }
            let path = String(rawPath[rawPath.index(after: slash)...])
            guard path.hasSuffix(".md") else { continue }
            result.append((path, String(decoding: bytes, as: UTF8.self)))
        }
        result.sort { $0.path < $1.path }
        progress(1)
        return result
    }

    private func downloadTarball(ref: String) async throws -> Data {
        let (data, code) = try await request("GET", "tarball/\(ref)")
        guard code == 200 else { throw error(data, code) }
        return data
    }

    /// 旧経路：対象 ref のツリーから .md を列挙し、GraphQL で本文をまとめ取りする。
    private func filesFromGraphQL(ref: String,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> [(path: String, content: String)] {
        let paths = try await allMarkdownPaths(ref: ref)
        guard !paths.isEmpty else { return [] }

        var result: [(path: String, content: String)] = []
        let batchSize = 100
        var index = 0
        while index < paths.count {
            let end = min(index + batchSize, paths.count)
            let batch = Array(paths[index..<end])
            let contents = try await fetchContentsBatch(batch, ref: ref)
            for (i, path) in batch.enumerated() {
                if let text = contents[i] { result.append((path, text)) }
            }
            index = end
            progress(Double(index) / Double(paths.count))
        }
        return result
    }

    /// 対象 ref（commit SHA またはブランチ名）のツリーから .md パスを列挙する。
    private func allMarkdownPaths(ref: String) async throws -> [String] {
        // ref が commit SHA ならそのツリーを直接、ブランチ名なら HEAD を解決してから取る。
        let treeSha: String?
        if let t = try await commitTreeSha(ref) {
            treeSha = t
        } else {
            let head = try await currentHead()
            guard head.exists, let headSha = head.sha else { return [] }
            treeSha = try await commitTreeSha(headSha)
        }
        guard let treeSha, let blobs = try await treeBlobs(treeSha) else {
            throw GitHubBackupError(message: "リポジトリが大きすぎて一覧を取得できませんでした。")
        }
        return blobs.keys.filter { $0.hasSuffix(".md") }.sorted()
    }

    /// GraphQL で複数パスの Blob.text をまとめて取得する。戻り値は paths と同じ並び（取得不可は nil）。
    private func fetchContentsBatch(_ paths: [String], ref: String) async throws -> [String?] {
        var fields = ""
        for (i, path) in paths.enumerated() {
            let expr = "\(ref):\(path)"
            fields += "f\(i): object(expression: \(Self.graphQLString(expr))) { ... on Blob { text } }\n"
        }
        let query = "query { repository(owner: \(Self.graphQLString(owner)), name: \(Self.graphQLString(repo))) {\n\(fields)} }"

        let (data, code) = try await graphQLRequest(query)
        guard code == 200 else { throw error(data, code) }
        guard let obj = json(data) else {
            throw GitHubBackupError(message: "復元データの取得に失敗しました。")
        }
        guard let dataObj = obj["data"] as? [String: Any],
              let repoObj = dataObj["repository"] as? [String: Any] else {
            if let errs = obj["errors"] as? [[String: Any]] {
                let msg = errs.compactMap { $0["message"] as? String }.joined(separator: " / ")
                throw GitHubBackupError(message: "GitHub GraphQL エラー: \(msg)")
            }
            throw GitHubBackupError(message: "復元データの取得に失敗しました。")
        }
        return paths.indices.map { i in
            (repoObj["f\(i)"] as? [String: Any])?["text"] as? String
        }
    }

    /// GraphQL の文字列リテラルとしてエスケープする（前後の " 込み）。
    private static func graphQLString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func graphQLRequest(_ query: String) async throws -> (Data, Int) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubBackupError(message: "URL が不正です。")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("couchNotes", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
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
