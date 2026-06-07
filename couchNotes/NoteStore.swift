//
//  NoteStore.swift
//  couchNotes
//
//  ノート本文・メタデータの永続ストア（純正 SQLite3）。
//  全件を SQLite に保持し、一覧／本文表示をローカルから即座に行う。
//  全文検索・バックリンクのスキーマもここに足していく。
//

import Foundation
import SQLite3

// sqlite3_bind_text に渡す「呼び出し中にコピーせよ」フラグ。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite を所有するアクター。すべてのアクセスを直列化し、メインスレッドを塞がない。
actor NoteStore {
    static let shared = NoteStore()
    private init() {}

    private var db: OpaquePointer?
    private var isBootstrapped = false

    // MARK: - 起動

    /// DB を開いてスキーマを用意する（多重呼び出し安全）。
    func bootstrap() {
        guard !isBootstrapped else { return }

        let url = Self.databaseURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open(url.path, &db) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            return
        }

        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS notes (
            id       TEXT PRIMARY KEY,
            path     TEXT,
            mtime    REAL,
            ctime    REAL,
            size     INTEGER,
            content  TEXT,
            frontmatter_extra TEXT,
            deleted  INTEGER DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_mtime ON notes(mtime DESC);")
        // 既存DBへの列追加（既にあればエラーは無視される）
        exec("ALTER TABLE notes ADD COLUMN frontmatter_extra TEXT;")
        exec("""
        CREATE TABLE IF NOT EXISTS sync_state (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
        """)
        // 全文検索（trigram：日本語のような非分かち書きでも部分一致できる）
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(id UNINDEXED, content, tokenize='trigram');")
        // 既存DBに FTS が無かった場合は本文から再構築
        if ftsCount() == 0 && count() > 0 {
            exec("INSERT INTO note_fts (id, content) SELECT id, content FROM notes WHERE deleted = 0;")
        }

        // バックリンク用：source_id（リンク元）→ target_key（リンク先の正規化キー）
        exec("CREATE TABLE IF NOT EXISTS links (source_id TEXT, target_key TEXT);")
        exec("CREATE INDEX IF NOT EXISTS idx_links_target ON links(target_key);")
        exec("CREATE INDEX IF NOT EXISTS idx_links_source ON links(source_id);")
        // 既存DBに links が無かった場合は本文から再構築
        if linksCount() == 0 && count() > 0 {
            rebuildLinks()
        }

        // 既存行に含まれるフロントマターを本文から分離（1回だけ）
        resplitExistingContent()

        isBootstrapped = true
    }

    private static func databaseURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("couchNotes.sqlite")
    }

    // MARK: - 参照

    /// 保存済みノート件数（初回インポート要否の判定に使う）。
    func count() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM notes WHERE deleted = 0;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// 一覧表示用アイテム（mtime 降順、プレビュー付き）。
    func listItems() -> [NoteItem] {
        // プレビューは先頭 400 文字だけ取り出し、表示側でトリム＆切り詰める。
        let sql = """
        SELECT id, path, mtime, substr(content, 1, 400)
        FROM notes WHERE deleted = 0
        ORDER BY mtime DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var items: [NoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id    = columnText(stmt, 0) ?? ""
            let path  = columnText(stmt, 1)
            let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let raw   = columnText(stmt, 3) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.isEmpty ? nil : String(trimmed.prefix(300))
            items.append(NoteItem(id: id, mtime: mtime, path: path, preview: preview))
        }
        return items
    }

    /// 本文（フロントマター除去済み）を取得（存在しなければ nil）。
    func content(_ id: String) -> String? {
        guard let stmt = prepare("SELECT content FROM notes WHERE id = ? AND deleted = 0;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
    }

    /// エディタ用：本文＋作成/更新時刻（ms）＋保持フロントマター。
    func editingNote(_ id: String) -> StoredNote? {
        let sql = "SELECT content, ctime, mtime, frontmatter_extra FROM notes WHERE id = ? AND deleted = 0;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let body  = columnText(stmt, 0) ?? ""
        let ctime = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
        let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
        let extra = columnText(stmt, 3)
        return StoredNote(body: body, ctime: ctime, mtime: mtime, extra: extra)
    }

    // MARK: - 全文検索

    /// 検索：タイトル（ファイル名）一致を先頭に、続けて本文一致を並べる。
    /// 本文一致は3文字以上で FTS5(trigram)、1〜2文字は LIKE フォールバック。
    func search(_ query: String) -> [NoteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let titleHits = titleSearch(trimmed)
        let titleIDs  = Set(titleHits.map(\.id))
        let contentHits = (trimmed.count >= 3 ? ftsSearch(trimmed) : likeSearch(trimmed))
            .filter { !titleIDs.contains($0.id) }
        return titleHits + contentHits
    }

    /// タイトル（ファイル名）に語句を含むノート。id で粗く絞り、basename で厳密判定。
    private func titleSearch(_ query: String) -> [NoteItem] {
        let sql = """
        SELECT id, path, mtime, substr(content, 1, 400)
        FROM notes
        WHERE deleted = 0 AND lower(id) LIKE ?
        ORDER BY mtime DESC
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        let q = query.lowercased()
        sqlite3_bind_text(stmt, 1, "%" + q + "%", -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: true).filter { $0.shortTitle.lowercased().contains(q) }
    }

    private func ftsSearch(_ query: String) -> [NoteItem] {
        // trigram では語をフレーズ（"..."）として渡すと部分一致になる。" は "" でエスケープ。
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let sql = """
        SELECT n.id, n.path, n.mtime, snippet(note_fts, 1, '', '', '…', 12)
        FROM note_fts
        JOIN notes n ON n.id = note_fts.id
        WHERE note_fts MATCH ? AND n.deleted = 0
        ORDER BY rank
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, phrase, -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: false)
    }

    private func likeSearch(_ query: String) -> [NoteItem] {
        let sql = """
        SELECT id, path, mtime, substr(content, 1, 400)
        FROM notes
        WHERE deleted = 0 AND content LIKE ?
        ORDER BY mtime DESC
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%" + query + "%", -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: true)
    }

    // MARK: - バックリンク

    /// この id を指している（リンク元の）ノート一覧。
    /// 解決規則は本文タップと同じ：フルパス一致 または ファイル名（basename）一致（小文字）。
    func backlinks(for id: String) -> [NoteItem] {
        let lower = id.lowercased()
        let full  = lower.hasSuffix(".md") ? String(lower.dropLast(3)) : lower
        let base  = full.components(separatedBy: "/").last ?? full
        let sql = """
        SELECT DISTINCT n.id, n.path, n.mtime, substr(n.content, 1, 400)
        FROM links l
        JOIN notes n ON n.id = l.source_id
        WHERE l.target_key IN (?, ?) AND n.deleted = 0 AND n.id != ?
        ORDER BY n.mtime DESC
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, full, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, base, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, id,   -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: true)
    }

    /// id, path, mtime, preview の4カラムを NoteItem 配列に変換する共通処理。
    private func readItems(_ stmt: OpaquePointer?, previewTrim: Bool) -> [NoteItem] {
        var items: [NoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id    = columnText(stmt, 0) ?? ""
            let path  = columnText(stmt, 1)
            let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let raw   = columnText(stmt, 3) ?? ""
            let preview: String?
            if previewTrim {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                preview = t.isEmpty ? nil : String(t.prefix(300))
            } else {
                preview = raw.isEmpty ? nil : raw
            }
            items.append(NoteItem(id: id, mtime: mtime, path: path, preview: preview))
        }
        return items
    }

    // MARK: - 更新

    /// 1 件を upsert（ctime は新規時のみ設定し、更新時は保持）。
    func upsert(_ r: NoteRecord) {
        upsert(r, on: db)
    }

    /// 複数件を 1 トランザクションで一括 upsert（初回インポート用）。
    func upsertMany(_ records: [NoteRecord]) {
        guard !records.isEmpty else { return }
        exec("BEGIN TRANSACTION;")
        for r in records { upsert(r, on: db) }
        exec("COMMIT;")
    }

    /// 削除（ソフト削除フラグを立てて一覧／検索から除外）。
    func delete(_ id: String) {
        guard let stmt = prepare("UPDATE notes SET deleted = 1 WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        deleteFTS(id)
        deleteLinks(id)
    }

    /// 同期対象から外れたフォルダ配下の行をローカルから物理削除する（サーバには影響なし）。
    func removeFolder(_ prefix: String) {
        guard !prefix.isEmpty else { return }
        // 保存されている id は小文字なので小文字で照合
        let pattern = prefix.lowercased() + "/%"
        for table in ["notes", "note_fts"] {
            if let stmt = prepare("DELETE FROM \(table) WHERE id LIKE ?;") {
                sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        if let stmt = prepare("DELETE FROM links WHERE source_id LIKE ?;") {
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func upsert(_ r: NoteRecord, on db: OpaquePointer?) {
        // フロントマターを分離し、本文のみを保存（表示・検索・プレビューを綺麗に保つ）
        let parsed = FrontmatterParser.split(r.content)
        let body   = parsed.body
        let extra  = parsed.extraLines.joined(separator: "\n")

        let sql = """
        INSERT INTO notes (id, path, mtime, ctime, size, content, frontmatter_extra, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            mtime = excluded.mtime,
            size = excluded.size,
            content = excluded.content,
            frontmatter_extra = excluded.frontmatter_extra,
            deleted = 0;
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, r.id, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, r.path)
        bindOptionalDouble(stmt, 3, r.mtime)
        bindOptionalDouble(stmt, 4, r.ctime)
        sqlite3_bind_int64(stmt, 5, Int64(r.size))
        sqlite3_bind_text(stmt, 6, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, extra, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)

        // 全文検索・バックリンクは本文のみで索引
        updateFTS(id: r.id, content: body)
        updateLinks(id: r.id, content: body)
    }

    // MARK: - FTS メンテナンス

    private func ftsCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM note_fts;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func updateFTS(id: String, content: String) {
        deleteFTS(id)
        guard let stmt = prepare("INSERT INTO note_fts (id, content) VALUES (?, ?);") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, content, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func deleteFTS(_ id: String) {
        guard let stmt = prepare("DELETE FROM note_fts WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - リンク（バックリンク）メンテナンス

    private static let wikiLinkRegex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)

    /// 本文から [[...]] を抜き出し、正規化済みのリンク先キー集合を返す。
    private static func parseLinkKeys(from content: String) -> [String] {
        guard let regex = wikiLinkRegex else { return [] }
        let ns = content as NSString
        var keys = Set<String>()
        for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2 else { continue }
            if let key = normalizeKey(ns.substring(with: m.range(at: 1))) { keys.insert(key) }
        }
        return Array(keys)
    }

    /// リンク表記を比較用キーに正規化（エイリアス/見出し除去・小文字・.md 除去）。
    private static func normalizeKey(_ raw: String) -> String? {
        var s = raw
        if let bar  = s.firstIndex(of: "|") { s = String(s[..<bar]) }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s = s.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix(".md") { s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return s.isEmpty ? nil : s
    }

    private func linksCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM links;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func updateLinks(id: String, content: String) {
        deleteLinks(id)
        let keys = Self.parseLinkKeys(from: content)
        guard !keys.isEmpty,
              let stmt = prepare("INSERT INTO links (source_id, target_key) VALUES (?, ?);")
        else { return }
        defer { sqlite3_finalize(stmt) }
        for key in keys {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id,  -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    private func deleteLinks(_ id: String) {
        guard let stmt = prepare("DELETE FROM links WHERE source_id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// 既存行（フロントマター混在）から本文を分離し、content/extra・索引を更新（1回だけ）。
    private func resplitExistingContent() {
        guard syncValue("content_split_v1") == nil else { return }

        var rows: [(String, String)] = []
        if let stmt = prepare("SELECT id, content FROM notes;") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((columnText(stmt, 0) ?? "", columnText(stmt, 1) ?? ""))
            }
            sqlite3_finalize(stmt)
        }

        exec("BEGIN TRANSACTION;")
        for (id, full) in rows {
            let parsed = FrontmatterParser.split(full)
            guard parsed.body != full else { continue }   // フロントマター無しはそのまま
            let extra = parsed.extraLines.joined(separator: "\n")
            if let stmt = prepare("UPDATE notes SET content = ?, frontmatter_extra = ? WHERE id = ?;") {
                sqlite3_bind_text(stmt, 1, parsed.body, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, extra, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            updateFTS(id: id, content: parsed.body)
            updateLinks(id: id, content: parsed.body)
        }
        exec("COMMIT;")
        setSyncValue("content_split_v1", "done")
    }

    /// 全ノートの本文から links を作り直す（既存DB初回のバックフィル）。
    private func rebuildLinks() {
        var rows: [(String, String)] = []
        if let stmt = prepare("SELECT id, content FROM notes WHERE deleted = 0;") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((columnText(stmt, 0) ?? "", columnText(stmt, 1) ?? ""))
            }
            sqlite3_finalize(stmt)
        }
        exec("BEGIN TRANSACTION;")
        for (id, content) in rows { updateLinks(id: id, content: content) }
        exec("COMMIT;")
    }

    // MARK: - 同期状態（last_seq など）

    func syncValue(_ key: String) -> String? {
        guard let stmt = prepare("SELECT value FROM sync_state WHERE key = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
    }

    func setSyncValue(_ key: String, _ value: String) {
        let sql = """
        INSERT INTO sync_state (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - SQLite ヘルパー

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }
}
