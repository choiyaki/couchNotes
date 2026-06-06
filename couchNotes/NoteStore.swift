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
            deleted  INTEGER DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_mtime ON notes(mtime DESC);")
        exec("""
        CREATE TABLE IF NOT EXISTS sync_state (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
        """)

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

    /// 本文を取得（存在しなければ nil）。
    func content(_ id: String) -> String? {
        guard let stmt = prepare("SELECT content FROM notes WHERE id = ? AND deleted = 0;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
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

    /// 削除（ソフト削除フラグを立てて一覧から除外）。
    func delete(_ id: String) {
        guard let stmt = prepare("UPDATE notes SET deleted = 1 WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func upsert(_ r: NoteRecord, on db: OpaquePointer?) {
        let sql = """
        INSERT INTO notes (id, path, mtime, ctime, size, content, deleted)
        VALUES (?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            mtime = excluded.mtime,
            size = excluded.size,
            content = excluded.content,
            deleted = 0;
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, r.id, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, r.path)
        bindOptionalDouble(stmt, 3, r.mtime)
        bindOptionalDouble(stmt, 4, r.ctime)
        sqlite3_bind_int64(stmt, 5, Int64(r.size))
        sqlite3_bind_text(stmt, 6, r.content, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
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
