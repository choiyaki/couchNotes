import Foundation
import CryptoKit

class CouchDBClient {
    static let shared = CouchDBClient()
    private init() {}

    private let chunkSize = 102400

    /// ドキュメントIDを URL の1パスセグメントとして扱うための文字セット。
    /// `.urlPathAllowed` は "/" を残すため、フォルダ区切りの "/" が
    /// パス区切り（＝別ドキュメント＋添付ファイル）と誤解釈される。"/" も明示的にエンコードする。
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

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

    /// ノートのメタ情報＋本文をまとめて取得（SQLite 保存用）
    func fetchNoteRecord(id: String) async throws -> NoteRecord? {
        guard let note = try await fetchNote(id: id) else { return nil }
        let content = try await fetchFullText(from: note.children)
        return NoteRecord(
            id: id, path: note.path, mtime: note.mtime,
            ctime: note.ctime, size: note.size, content: content
        )
    }

    /// 指定フォルダ範囲のノートを本文込みで一括取得
    /// - includeRoot: ルート直下（"/" を含まない id）も含めるか
    /// - folders: 正規化済みフォルダ名（各 "<folder>/" 配下を取得）
    func fetchScopedNotes(
        folders: [String],
        includeRoot: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [NoteRecord] {
        try await fetchNotes(
            selector: scopeSelector(folders: folders, includeRoot: includeRoot),
            progress: progress
        )
    }

    /// 同期範囲を表す Mango selector を組み立てる
    private func scopeSelector(folders: [String], includeRoot: Bool) -> [String: Any] {
        var ors: [[String: Any]] = []
        if includeRoot {
            // ルート直下＝スラッシュを含まない id
            ors.append(["_id": ["$regex": "^[^/]+$"]])
        }
        for f in folders where !f.isEmpty {
            // "<folder>/..." の範囲（"0" は "/" の次の文字）。子フォルダも含む。
            ors.append(["_id": ["$gte": "\(f)/", "$lt": "\(f)0"]])
        }
        var selector: [String: Any] = ["type": ["$eq": "plain"]]
        if !ors.isEmpty { selector["$or"] = ors }
        return selector
    }

    /// selector に一致するノートを本文込みで一括取得（初回／バックフィル共通）
    /// - _find でメタ＋children を取得 → 全チャンクを `_bulk_get` でバッチ取得 → 本文を組み立て
    /// - progress: 0...1 のダウンロード進捗（チャンク取得ベース）
    private func fetchNotes(
        selector: [String: Any],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [NoteRecord] {
        // 1) ノートのメタ + children
        let query: [String: Any] = [
            "selector": selector,
            "fields":   ["_id", "path", "mtime", "ctime", "size", "children", "deleted"],
            "limit":    99999
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: query) else {
            throw CouchDBError.decodingError
        }
        let (data, code) = try await httpRequest(path: "_find", method: "POST", body: body)
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let resp = try? JSONDecoder().decode(FullFindResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }

        let docs = resp.docs.filter {
            $0._id.hasSuffix(".md") && !$0._id.hasPrefix("h:") && $0.deleted != true
        }

        // 2) 全チャンクIDを集約・重複排除（内容ハッシュなので自然に共有される）
        var chunkIDset = Set<String>()
        for d in docs { for c in (d.children ?? []) { chunkIDset.insert(c) } }
        let allChunkIDs = Array(chunkIDset)

        // 3) _bulk_get で 1000 件ずつバッチ取得
        var chunkData: [String: String] = [:]
        let batchSize = 1000
        let total = max(allChunkIDs.count, 1)
        var fetched = 0
        var index = 0
        while index < allChunkIDs.count {
            let end   = min(index + batchSize, allChunkIDs.count)
            let batch = Array(allChunkIDs[index..<end])
            let map   = try await bulkGetChunks(ids: batch)
            for (k, v) in map { chunkData[k] = v }
            fetched += batch.count
            progress?(Double(fetched) / Double(total))
            index = end
        }

        // 4) 本文を組み立て
        return docs.map { d in
            let content = (d.children ?? []).map { chunkData[$0] ?? "" }.joined()
            return NoteRecord(
                id: d._id, path: d.path, mtime: d.mtime,
                ctime: d.ctime, size: d.size ?? content.utf8.count, content: content
            )
        }
    }

    /// 現在の update_seq を取得（初回インポート後、_changes の起点に使う）
    func currentUpdateSeq() async throws -> String {
        let (data, code) = try await httpRequest(path: "")
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["update_seq"] as? String { return s }
            if let n = obj["update_seq"] as? Int    { return String(n) }
        }
        return "now"
    }

    private func bulkGetChunks(ids: [String]) async throws -> [String: String] {
        let payload: [String: Any] = ["docs": ids.map { ["id": $0] }]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CouchDBError.decodingError
        }
        let (data, code) = try await httpRequest(path: "_bulk_get", method: "POST", body: body)
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let resp = try? JSONDecoder().decode(BulkGetResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }
        var out: [String: String] = [:]
        for r in resp.results {
            for d in r.docs {
                if let ok = d.ok { out[ok._id] = ok.data }
            }
        }
        return out
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

    /// ノートを削除（CouchDB ネイティブ削除＝トゥームストーン化）
    /// 最新の _rev を取得してから DELETE する。既に存在しなければ何もしない。
    func deleteNote(id: String) async throws {
        guard let note = try await fetchNote(id: id) else { return }
        guard let rev = note._rev else { throw CouchDBError.decodingError }
        let (data, code) = try await httpRequest(
            path: id, method: "DELETE", headers: ["If-Match": rev]
        )
        // 200(ok) / 202(accepted) を成功とみなす
        if code != 200 && code != 202 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// ノートを別フォルダへ移動する。_id ＝ パスのため「新IDで作成＋旧ID削除」で行う。
    /// 本文チャンク（children）は共有なので再利用する。
    /// - toId: 新しい _id（小文字パス）, newPath: 表示用パス（大小保持）
    func moveNote(fromId: String, toId: String, newPath: String) async throws {
        guard toId != fromId else { return }
        // 移動先に同名ノートがある場合は上書きを避けて中止
        if try await fetchNote(id: toId) != nil {
            throw CouchDBError.httpError(409, "移動先に同名のノートが存在します")
        }
        guard let old = try await fetchNote(id: fromId) else {
            throw CouchDBError.httpError(404, "元のノートが見つかりません")
        }
        var moved = LiveSyncNote(id: toId, children: old.children, size: old.size, ctime: old.ctime)
        moved.path = newPath
        try await putNote(moved)
        try await deleteNote(id: fromId)
    }

    /// パスを明示して新規ノートを作成する（_id は小文字、path は大小保持）。
    /// 既に同 _id がある場合は中止。
    func createNote(id: String, path: String, text: String) async throws {
        if try await fetchNote(id: id) != nil {
            throw CouchDBError.httpError(409, "同名のノートが既に存在します")
        }
        let (chunkIDs, chunks) = makeChunks(text: text)
        try await putChunks(chunks)
        var note = LiveSyncNote(id: id, children: chunkIDs, size: text.utf8.count)
        note.path = path
        try await putNote(note)
    }

    /// 本文は変えず ctime/mtime だけ更新する（移行：YAMLを正としてメタデータへ反映）。
    func updateNoteTimes(id: String, ctime: Double, mtime: Double) async throws {
        guard var note = try await fetchNote(id: id) else { return }
        note.ctime = ctime
        note.mtime = mtime
        try await putNote(note)
    }

    /// 本文を保存しつつ ctime/mtime を明示指定する（移行：YAML付与で時刻を据え置く）。
    func saveContentPreservingTimes(id: String, text: String, ctime: Double, mtime: Double) async throws {
        let (chunkIDs, chunks) = makeChunks(text: text)
        try await putChunks(chunks)
        if var note = try await fetchNote(id: id) {
            note.children = chunkIDs
            note.ctime    = ctime
            note.mtime    = mtime
            note.size     = text.utf8.count
            try await putNote(note)
        } else {
            var note = LiveSyncNote(id: id, children: chunkIDs, size: text.utf8.count, ctime: ctime)
            note.mtime = mtime
            try await putNote(note)
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
        body: Data? = nil,
        headers: [String: String]? = nil
    ) async throws -> (Data, Int) {
        let (base, auth) = try makeBase()
        let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? path
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
        for (key, value) in headers ?? [:] {
            req.setValue(value, forHTTPHeaderField: key)
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

// MARK: - 一括取得用レスポンス

/// _find（本文込みの全件取得）用
private struct FullFindResponse: Decodable {
    struct Doc: Decodable {
        let _id: String
        let path: String?
        let mtime: Double?
        let ctime: Double?
        let size: Int?
        let children: [String]?
        let deleted: Bool?
    }
    let docs: [Doc]
}

/// _bulk_get（チャンク一括取得）用
private struct BulkGetResponse: Decodable {
    struct Result: Decodable {
        struct DocWrap: Decodable {
            struct OK: Decodable {
                let _id: String
                let data: String
            }
            let ok: OK?
        }
        let docs: [DocWrap]
    }
    let results: [Result]
}
