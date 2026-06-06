import Foundation
import CryptoKit

class CouchDBClient {
    static let shared = CouchDBClient()
    private init() {}

    private let chunkSize = 102400

    // MARK: - 接続情報

    private func makeBase() throws -> (url: String, auth: String) {
        let km = KeychainManager.shared
        guard
            let host     = km.load(key: "couchdb_host"),     !host.isEmpty,
            let dbName   = km.load(key: "couchdb_db"),       !dbName.isEmpty,
            let username = km.load(key: "couchdb_user"),     !username.isEmpty,
            let password = km.load(key: "couchdb_password"), !password.isEmpty
        else { throw CouchDBError.invalidSettings }

        let auth = "\(username):\(password)".data(using: .utf8)!.base64EncodedString()
        return ("\(host)/\(dbName)", auth)
    }

    // MARK: - 公開 API

    /// 全ノートを更新日時順（新しい順）で取得
    func fetchAllNoteIDs() async throws -> [NoteItem] {
        let query: [String: Any] = [
            "selector": ["type": ["$eq": "plain"]],
            "fields":   ["_id", "mtime", "path"],
            "limit":    99999
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: query) else {
            throw CouchDBError.decodingError
        }

        let (data, code) = try await httpRequest(path: "_find", method: "POST", body: body)
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let response = try? JSONDecoder().decode(MangoResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }

        return response.docs
            .filter { $0.id.hasSuffix(".md") && !$0.id.hasPrefix("h:") }
            .map    { NoteItem(id: $0.id, mtime: $0.mtime, path: $0.path) }
            .sorted { ($0.mtime ?? 0) > ($1.mtime ?? 0) }
    }

    /// ノート本文を取得
    func fetchNoteContent(id: String) async throws -> String {
        guard let note = try await fetchNote(id: id) else { return "" }
        return try await fetchFullText(from: note.children)
    }

    /// ノート本文を保存（存在しない場合は新規作成）
    func saveNoteContent(id: String, text: String) async throws {
        if let existing = try await fetchNote(id: id) {
            try await saveText(text, to: existing)
        } else {
            let (chunkIDs, chunks) = makeChunks(text: text)
            try await putChunks(chunks)
            let newNote = LiveSyncNote(id: id, children: chunkIDs, size: text.utf8.count)
            try await putNote(newNote)
        }
    }

    /// _changes longpoll 用の URLRequest を生成
    /// - Parameter since: "now" または前回レスポンスの last_seq
    func makeChangesURLRequest(since: String = "now") throws -> URLRequest {
        let (base, auth) = try makeBase()
        let urlStr = "\(base)/_changes"
            + "?feed=longpoll"      // continuous → longpoll に変更
            + "&since=\(since)"
            + "&timeout=30000"      // 30秒待機。変更があれば即返す
            + "&include_docs=false"
        guard let url = URL(string: urlStr) else { throw CouchDBError.invalidSettings }

        var req = URLRequest(url: url)
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        // longpoll は最長30秒で必ずレスポンスが返る
        // URLRequest のタイムアウトはそれより長く設定する
        req.timeoutInterval = 60
        return req
    }

    func todayNoteID() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        return "\(df.string(from: Date())).md"
    }

    // MARK: - 内部処理

    private func saveText(_ text: String, to note: LiveSyncNote) async throws {
        let (chunkIDs, chunks) = makeChunks(text: text)
        try await putChunks(chunks)
        var updated      = note
        updated.children = chunkIDs
        updated.mtime    = Date().timeIntervalSince1970 * 1000
        updated.size     = text.utf8.count
        try await putNote(updated)
    }

    private func makeChunks(text: String) -> ([String], [LiveSyncChunk]) {
        let bytes = Array(text.utf8)
        var chunks: [LiveSyncChunk] = []
        var ids: [String] = []
        var offset = 0

        while offset < bytes.count {
            let end   = min(offset + chunkSize, bytes.count)
            let slice = Data(bytes[offset..<end])
            let chunk = String(data: slice, encoding: .utf8) ?? ""
            let cid   = "h:\(sha1prefix(chunk))"
            chunks.append(LiveSyncChunk(_id: cid, data: chunk))
            ids.append(cid)
            offset = end
        }

        if chunks.isEmpty {
            let cid = "h:\(sha1prefix(text))"
            chunks.append(LiveSyncChunk(_id: cid, data: text))
            ids.append(cid)
        }

        return (ids, chunks)
    }

    private func sha1prefix(_ text: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(13))
    }

    private func fetchFullText(from chunkIDs: [String]) async throws -> String {
        var result = ""
        for id in chunkIDs { result += try await fetchChunk(id: id).data }
        return result
    }

    private func httpRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, Int) {
        let (base, auth) = try makeBase()
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(base)/\(encoded)") else {
            throw CouchDBError.invalidSettings
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            throw CouchDBError.networkError(error)
        }
    }

    private func fetchNote(id: String) async throws -> LiveSyncNote? {
        let (data, code) = try await httpRequest(path: id)
        if code == 404 { return nil }
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try? JSONDecoder().decode(LiveSyncNote.self, from: data)
    }

    private func fetchChunk(id: String) async throws -> LiveSyncChunk {
        let (data, code) = try await httpRequest(path: id)
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let chunk = try? JSONDecoder().decode(LiveSyncChunk.self, from: data) else {
            throw CouchDBError.decodingError
        }
        return chunk
    }

    private func putNote(_ note: LiveSyncNote) async throws {
        let body = try JSONEncoder().encode(note)
        let (data, code) = try await httpRequest(path: note._id, method: "PUT", body: body)
        if code != 200 && code != 201 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func putChunks(_ chunks: [LiveSyncChunk]) async throws {
        for chunk in chunks {
            let (_, code) = try await httpRequest(path: chunk._id)
            if code == 200 { continue }
            let body = try JSONEncoder().encode(chunk)
            let (data, putCode) = try await httpRequest(path: chunk._id, method: "PUT", body: body)
            if putCode != 200 && putCode != 201 {
                throw CouchDBError.httpError(putCode, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
