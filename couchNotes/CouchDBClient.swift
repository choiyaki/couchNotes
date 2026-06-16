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

    /// ノートのメタ情報＋本文をまとめて取得（SQLite 保存用）。
    /// LiveSync のソフト削除（deleted:true）は「存在しない」として nil を返す。
    func fetchNoteRecord(id: String) async throws -> NoteRecord? {
        guard let note = try await fetchNote(id: id) else { return nil }
        if note.deleted == true { return nil }
        let content = try await fetchFullText(from: note.children)
        return NoteRecord(
            id: id, path: note.path, mtime: note.mtime,
            ctime: note.ctime, size: note.size, content: content,
            rev: note._rev
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
            // _id は小文字なので小文字化して範囲指定（"0" は "/" の次の文字）。子フォルダも含む。
            let lf = f.lowercased()
            ors.append(["_id": ["$gte": "\(lf)/", "$lt": "\(lf)0"]])
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
            "fields":   ["_id", "_rev", "path", "mtime", "ctime", "size", "children", "deleted"],
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
                ctime: d.ctime, size: d.size ?? content.utf8.count, content: content,
                rev: d._rev
            )
        }
    }

    /// 指定 id 群のノートを本文込みで一括取得する（_changes の差分取り込み用）。
    /// 削除（トゥームストーン）やルート外などは結果に含まれない（削除は _changes の deleted:true で判定）。
    func fetchNoteRecords(ids: [String]) async throws -> [NoteRecord] {
        guard !ids.isEmpty else { return [] }
        return try await fetchNotes(selector: ["type": ["$eq": "plain"], "_id": ["$in": ids]])
    }

    /// サーバ上に「生存している」ノート（.md・同期スコープ内）の id→rev マップを返す。
    /// _all_docs は本文を含まず、削除済み（墓標）は既定で返さないので、リコンシリエーションの
    /// 「正＝サーバ」の存在集合＋世代をまとめて軽量に取得できる。
    func liveNoteRevs(folders: [String]) async throws -> [String: String] {
        let (data, code) = try await httpRequest(path: "_all_docs")
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let resp = try? JSONDecoder().decode(AllDocsRevResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }
        var out: [String: String] = [:]
        for row in resp.rows {
            guard let id = row.id, let rev = row.value?.rev else { continue }
            guard id.hasSuffix(".md"), !id.hasPrefix("h:"),
                  SyncScope.shouldSync(id: id, folders: folders) else { continue }
            out[id] = rev
        }
        return out
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

    /// 本文を保存（楽観ロック）。baseRev を明示し、サーバがそれより進んでいれば 409 を投げる（再取得しない）。
    /// baseRev=nil は新規作成（既存・墓標があれば 409）。成功時は新しい _rev を返す。
    /// これにより「編集 vs 編集」「削除 vs 編集」の競合を呼び出し側で検知できる。
    @discardableResult
    func saveNoteContentChecked(id: String, path: String, text: String,
                                ctime: Double, baseRev: String?) async throws -> String {
        let (chunkIDs, chunks) = makeChunks(text: text)
        try await putChunks(chunks)
        var note   = LiveSyncNote(id: id, children: chunkIDs, size: text.utf8.count, ctime: ctime)
        note.path  = path
        note._rev  = baseRev   // nil なら新規作成（_rev は出力されない）
        let body   = try JSONEncoder().encode(note)
        let (data, code) = try await httpRequest(path: id, method: "PUT", body: body)
        if code == 409 { throw CouchDBError.httpError(409, "conflict") }
        if code != 200 && code != 201 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rev = obj["rev"] as? String { return rev }
        return ""
    }

    /// ドキュメントの現在の _rev を返す（削除済み＝墓標でも取得できる）。存在しなければ nil。
    /// 墓標の上に新しいリビジョンを作る（削除されたノートに編集を復元する）ために使う。
    /// _all_docs を keys 指定で引くと、削除済みでも value.rev（と deleted:true）が返る（open_revs より堅牢）。
    func currentLeafRev(id: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: ["keys": [id]])
        let (data, code) = try await httpRequest(path: "_all_docs", method: "POST", body: body)
        guard code == 200 else { return nil }
        guard let resp = try? JSONDecoder().decode(AllDocsRevResponse.self, from: data) else { return nil }
        return resp.rows.first?.value?.rev
    }

    /// ノートを削除（CouchDB ネイティブ削除＝トゥームストーン）。
    /// 単一の Remote CouchDB を正本とするためソフト削除（独自 deleted:true）は使わない。
    /// _changes に deleted:true として流れ、他端末はそれを唯一の削除信号として反映する。
    /// 本文フィールドは消え、極小の墓標（_id/_rev/_deleted）だけが残る。既に無ければ何もしない。
    func deleteNote(id: String) async throws {
        // 競合（409）に備えて rev を取り直して最大2回まで試行する。
        for _ in 0..<2 {
            guard let note = try await fetchNote(id: id), let rev = note._rev else { return }
            let body = try JSONSerialization.data(withJSONObject: ["_id": id, "_rev": rev, "_deleted": true])
            let (data, code) = try await httpRequest(path: id, method: "PUT", body: body)
            if code == 200 || code == 201 { return }
            if code == 409 { continue }   // 競合：rev を取り直して再試行
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        throw CouchDBError.httpError(409, "削除が競合しました")
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

    /// path・ctime・mtime を明示してノートを作成/更新する（リネーム＝新ID作成に使用）。
    /// - requireAbsent: true なら既存IDがある場合は中止（上書き防止）。
    func putNoteContent(
        id: String, path: String, text: String,
        ctime: Double, mtime: Double, requireAbsent: Bool = false
    ) async throws {
        if requireAbsent, try await fetchNote(id: id) != nil {
            throw CouchDBError.httpError(409, "同名のノートが既に存在します")
        }
        let (chunkIDs, chunks) = makeChunks(text: text)
        try await putChunks(chunks)
        if var note = try await fetchNote(id: id) {
            note.children = chunkIDs
            note.path     = path
            note.ctime    = ctime
            note.mtime    = mtime
            note.size     = text.utf8.count
            try await putNote(note)
        } else {
            var note = LiveSyncNote(id: id, children: chunkIDs, size: text.utf8.count, ctime: ctime)
            note.path  = path
            note.mtime = mtime
            try await putNote(note)
        }
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

    /// 削除済み(deleted:true)ノートと、それだけが参照する孤児チャンクを物理削除(_purge)する。
    /// 戻り値＝(削除したノート数, 削除したチャンク数)。progress は 0...1。
    /// ※ 全端末が削除を同期済みの前提で実行すること（未同期端末があると復活し得る）。
    func purgeDeletedNotes(progress: @escaping @Sendable (Double) -> Void) async throws -> (notes: Int, chunks: Int) {
        // 1) children を持つドキュメント（＝ノート類）を全取得し、削除済み/生存を仕分け
        let query: [String: Any] = [
            "selector": ["children": ["$exists": true]],
            "fields":   ["_id", "children", "deleted"],
            "limit":    999999
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: query) else {
            throw CouchDBError.decodingError
        }
        let (data, code) = try await httpRequest(path: "_find", method: "POST", body: body)
        if code != 200 {
            throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let resp = try? JSONDecoder().decode(PurgeFindResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }

        var deletedIds: [String] = []
        var deletedChunks = Set<String>()
        var liveChunks = Set<String>()
        for doc in resp.docs {
            let children = doc.children ?? []
            if doc.deleted == true {
                deletedIds.append(doc._id)
                children.forEach { deletedChunks.insert($0) }
            } else {
                children.forEach { liveChunks.insert($0) }
            }
        }
        // 生存ノートが参照していないチャンクだけが孤児（共有チャンクの誤削除を防ぐ）
        let orphanChunks = Array(deletedChunks.subtracting(liveChunks))
        let allIds = deletedIds + orphanChunks
        guard !allIds.isEmpty else { return (0, 0) }

        // 2) 各ドキュメントの最新 rev を取得（_purge に必要）
        let revs = try await fetchRevs(ids: allIds)

        // 3) _purge をバッチ実行
        let deletedSet = Set(deletedIds)
        var purgedNotes = 0
        var purgedChunks = 0
        let batchSize = 100
        var index = 0
        while index < allIds.count {
            let end = min(index + batchSize, allIds.count)
            var purgeBody: [String: [String]] = [:]
            for id in allIds[index..<end] { if let rev = revs[id] { purgeBody[id] = [rev] } }
            if !purgeBody.isEmpty {
                let pdata = try JSONSerialization.data(withJSONObject: purgeBody)
                let (rdata, rcode) = try await httpRequest(path: "_purge", method: "POST", body: pdata)
                if rcode != 200 && rcode != 201 {
                    throw CouchDBError.httpError(rcode, String(data: rdata, encoding: .utf8) ?? "")
                }
                for id in purgeBody.keys {
                    if deletedSet.contains(id) { purgedNotes += 1 } else { purgedChunks += 1 }
                }
            }
            index = end
            progress(Double(index) / Double(allIds.count))
        }
        return (purgedNotes, purgedChunks)
    }

    /// _all_docs で id→rev をまとめて取得。
    private func fetchRevs(ids: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        let batchSize = 1000
        var index = 0
        while index < ids.count {
            let end = min(index + batchSize, ids.count)
            let batch = Array(ids[index..<end])
            let body = try JSONSerialization.data(withJSONObject: ["keys": batch])
            let (data, code) = try await httpRequest(path: "_all_docs", method: "POST", body: body)
            if code != 200 {
                throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
            }
            if let resp = try? JSONDecoder().decode(AllDocsRevResponse.self, from: data) {
                for row in resp.rows {
                    if let id = row.id, let rev = row.value?.rev { result[id] = rev }
                }
            }
            index = end
        }
        return result
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

    // MARK: - 復元（GitHub バックアップからの一括書き戻し）

    /// (path, content) 群を CouchDB へ一括投入する（上書き＋追記）。戻り値＝書き込んだノート数。
    /// id は path を小文字化（LiveSync 仕様）、ctime/mtime はフロントマターの created/updated から復元。
    /// チャンクは内容アドレス（h:<sha>）なので既存分は conflict として無視する。progress は 0...1。
    func restore(files: [(path: String, content: String)],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        guard !files.isEmpty else { return 0 }

        // 1. ノートとチャンクを構築（チャンクは id で重複排除）
        var notes: [LiveSyncNote] = []
        var chunkMap: [String: LiveSyncChunk] = [:]
        for f in files {
            let parsed = FrontmatterParser.split(f.content)
            let (chunkIDs, chunks) = makeChunks(text: f.content)
            for c in chunks { chunkMap[c._id] = c }
            var note = LiveSyncNote(id: f.path.lowercased(),
                                    children: chunkIDs,
                                    size: f.content.utf8.count,
                                    ctime: parsed.created.map { Double($0) * 1000 })
            note.path = f.path
            if let updated = parsed.updated { note.mtime = Double(updated) * 1000 }
            notes.append(note)
        }

        // 2. チャンクを一括投入（既存 h: は不変＝conflict は無視）
        let chunkDocs = try chunkMap.values.map { try encodeDoc($0) }
        try await bulkPut(chunkDocs, batchSize: 100, ignoreConflict: true) { frac in
            progress(frac * 0.5)
        }

        // 3. 既存ノートの _rev を解決して上書き、新規はそのまま作成
        let revs = try await existingRevs(ids: notes.map { $0._id })
        let noteDocs: [[String: Any]] = try notes.map { note in
            var dict = try encodeDoc(note)
            if let rev = revs[note._id] { dict["_rev"] = rev }
            return dict
        }
        try await bulkPut(noteDocs, batchSize: 200, ignoreConflict: false) { frac in
            progress(0.5 + frac * 0.5)
        }
        return notes.count
    }

    /// 指定 id 群の現在の _rev を _all_docs でまとめて取得する（存在しないものは含まれない）。
    private func existingRevs(ids: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        let batchSize = 1000
        var index = 0
        while index < ids.count {
            let end = min(index + batchSize, ids.count)
            let body = try JSONSerialization.data(withJSONObject: ["keys": Array(ids[index..<end])])
            let (data, code) = try await httpRequest(path: "_all_docs", method: "POST", body: body)
            if code != 200 {
                throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
            }
            if let resp = try? JSONDecoder().decode(AllDocsRevResponse.self, from: data) {
                for row in resp.rows {
                    if let id = row.id, let rev = row.value?.rev { result[id] = rev }
                }
            }
            index = end
        }
        return result
    }

    /// _bulk_docs で複数ドキュメントをバッチ投入する。ignoreConflict=true なら conflict は無視。
    private func bulkPut(_ docs: [[String: Any]],
                         batchSize: Int,
                         ignoreConflict: Bool,
                         progress: @Sendable (Double) -> Void) async throws {
        guard !docs.isEmpty else { progress(1); return }
        var index = 0
        while index < docs.count {
            let end = min(index + batchSize, docs.count)
            let body = try JSONSerialization.data(withJSONObject: ["docs": Array(docs[index..<end])])
            let (data, code) = try await httpRequest(path: "_bulk_docs", method: "POST", body: body)
            if code != 201 && code != 200 {
                throw CouchDBError.httpError(code, String(data: data, encoding: .utf8) ?? "")
            }
            // 各ドキュメントの結果を確認（conflict 以外のエラーは中断）
            if let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for r in results {
                    if let err = r["error"] as? String {
                        if err == "conflict" && ignoreConflict { continue }
                        let reason = (r["reason"] as? String) ?? err
                        throw CouchDBError.httpError(code, "bulk_docs: \(err) (\(reason))")
                    }
                }
            }
            index = end
            progress(Double(end) / Double(docs.count))
        }
    }

    private func encodeDoc<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
        headers: [String: String]? = nil,
        query: String? = nil
    ) async throws -> (Data, Int) {
        let (base, auth) = try makeBase()
        let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? path
        let urlStr  = "\(base)/\(encoded)" + (query.map { "?\($0)" } ?? "")
        guard let url = URL(string: urlStr) else {
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
        let _rev: String?
        let path: String?
        let mtime: Double?
        let ctime: Double?
        let size: Int?
        let children: [String]?
        let deleted: Bool?
    }
    let docs: [Doc]
}

/// _purge 用：children を持つドキュメントの仕分け
private struct PurgeFindResponse: Decodable {
    struct Doc: Decodable {
        let _id: String
        let children: [String]?
        let deleted: Bool?
    }
    let docs: [Doc]
}

/// _all_docs で rev を取得する用
private struct AllDocsRevResponse: Decodable {
    struct Row: Decodable {
        let id: String?
        struct Value: Decodable { let rev: String? }
        let value: Value?
    }
    let rows: [Row]
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
