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

/// 他アプリと共有するリンク索引の1エントリ。
/// key=照合用の正規化キー（小文字）, title=挿入・表示名（大小保持）,
/// path=実在ノートの LiveSync `_id`（＝小文字のパス。言及のみは nil＝省略）,
/// exists=実在ノートか（言及のみは false）。
struct LinkIndexEntry: Codable, Hashable {
    let key: String
    let title: String
    let path: String?
    let exists: Bool
}

/// トップレベルフォルダ単位の索引グループ（＝CouchDB 上の1文書に対応）。
/// groupKey="" はルート。folder は表示用のフォルダ名（大小保持、ルートは nil）。
/// 端末はフォルダ単位（トップレベル）で同期するので、同じ groupKey を書く端末どうしは
/// 内容が一致し、文書が競合しない（部分同期でも上書き合戦にならない）。
struct LinkIndexFolderGroup {
    let groupKey: String
    let folder: String?
    let entries: [LinkIndexEntry]
}

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
        exec("ALTER TABLE notes ADD COLUMN rev TEXT;")   // リコンシリエーションの世代比較用
        exec("ALTER TABLE notes ADD COLUMN sync_state TEXT;")   // clean / dirty / pendingDelete（NULL=clean扱い）
        exec("ALTER TABLE notes ADD COLUMN pin INTEGER;")   // ピン留め番号（frontmatter_extra の pin: N をキャッシュ）
        exec("CREATE INDEX IF NOT EXISTS idx_notes_pin ON notes(pin);")
        exec("ALTER TABLE notes ADD COLUMN id_folded TEXT;")   // id の NFKC+小文字化コピー（全角/半角を無視したタイトル検索・リンク解決用）
        exec("CREATE INDEX IF NOT EXISTS idx_notes_id_folded ON notes(id_folded);")
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

        // バックリンク用：source_id（リンク元）→ target_key（リンク先の正規化キー・小文字）
        exec("CREATE TABLE IF NOT EXISTS links (source_id TEXT, target_key TEXT);")
        exec("CREATE INDEX IF NOT EXISTS idx_links_target ON links(target_key);")
        exec("CREATE INDEX IF NOT EXISTS idx_links_source ON links(source_id);")
        // 表示用の原文（大小保持・別名/見出し/.md 除去済み）。索引の未作成ページの title に使う。
        exec("ALTER TABLE links ADD COLUMN target_display TEXT;")   // 既にあればエラー無視
        // target_display を持たせる移行（既存 DB は本文から一度だけ作り直す）。初回バックフィルも兼ねる。
        if syncValue("links_display_v1") == nil {
            if count() > 0 { rebuildLinks() }
            setSyncValue("links_display_v1", "done")
        } else if linksCount() == 0 && count() > 0 {
            rebuildLinks()
        }

        // 既存行に含まれるフロントマターを本文から分離（1回だけ）
        resplitExistingContent()

        // 全角/半角の不一致でタイトル検索・本文検索・[[ ]] リンク解決が失敗する不具合の是正。
        // id_folded のバックフィル、FTS 索引・リンクキーの全角/半角折りたたみ込みでの作り直し（1回だけ）。
        if syncValue("width_fold_v1") == nil {
            if count() > 0 {
                backfillIDFolded()
                rebuildFTSFolded()
                rebuildLinks()
            }
            setSyncValue("width_fold_v1", "done")
        }

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

    /// 末尾のファイル名（basename）が一致する生存ノートの id を返す。
    /// 複数該当する場合は最近更新したものを優先。basenameLower は ".md" 込み・小文字。
    func findIDByBasename(_ basenameLower: String) -> String? {
        guard let stmt = prepare("SELECT id FROM notes WHERE deleted = 0 ORDER BY mtime DESC;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let id   = String(cString: c)   // 保存時に小文字化済み
            let base = id.components(separatedBy: "/").last ?? id
            if base == basenameLower { return id }
        }
        return nil
    }

    /// 生存ノートの id→rev マップ（リコンシリエーション用）。rev 未取得は空文字。
    func idRevMap() -> [String: String] {
        guard let stmt = prepare("SELECT id, rev FROM notes WHERE deleted = 0;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id  = String(cString: idC)
            let rev = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out[id] = rev
        }
        return out
    }

    /// 一覧表示用アイテム（mtime 降順、プレビュー付き）。
    func listItems() -> [NoteItem] {
        // プレビューは先頭 400 文字だけ取り出し、表示側でトリム＆切り詰める。
        let sql = """
        SELECT id, path, mtime, substr(content, 1, 400), pin
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
            let pin   = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4))
            items.append(NoteItem(id: id, mtime: mtime, path: path, preview: preview, pin: pin))
        }
        return items
    }

    /// 本文（フロントマター除去後）が空白のみのノート一覧（mtime 降順）。
    /// ピン留め中のノートは誤削除防止のため対象外。
    func emptyBodyItems() -> [NoteItem] {
        guard let stmt = prepare("SELECT id, path, mtime, content FROM notes WHERE deleted = 0 AND pin IS NULL;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [NoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raw = columnText(stmt, 3) ?? ""
            guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let id    = columnText(stmt, 0) ?? ""
            let path  = columnText(stmt, 1)
            let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            items.append(NoteItem(id: id, mtime: mtime, path: path, preview: nil))
        }
        return items.sorted { ($0.mtime ?? 0) > ($1.mtime ?? 0) }
    }

    /// 現在ピン留めされている最大の番号（無ければ nil）。次のピン番号採番に使う。
    func maxPin() -> Int? {
        guard let stmt = prepare("SELECT MAX(pin) FROM notes WHERE deleted = 0;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// ピン留め中のノートを番号昇順で列挙する（繰り上げ処理用）。
    func pinnedIDs() -> [(id: String, pin: Int)] {
        guard let stmt = prepare("SELECT id, pin FROM notes WHERE deleted = 0 AND pin IS NOT NULL ORDER BY pin ASC;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(id: String, pin: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id  = columnText(stmt, 0) ?? ""
            let pin = Int(sqlite3_column_int64(stmt, 1))
            out.append((id: id, pin: pin))
        }
        return out
    }

    /// 本文（フロントマター除去済み）を取得（存在しなければ nil）。
    func content(_ id: String) -> String? {
        guard let stmt = prepare("SELECT content FROM notes WHERE id = ? AND deleted = 0;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
    }

    /// エディタ用：本文＋作成/更新時刻（ms）＋保持フロントマター＋パス。
    func editingNote(_ id: String) -> StoredNote? {
        let sql = "SELECT content, ctime, mtime, frontmatter_extra, path, rev FROM notes WHERE id = ? AND deleted = 0;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let body  = columnText(stmt, 0) ?? ""
        let ctime = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
        let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
        let extra = columnText(stmt, 3)
        let path  = columnText(stmt, 4)
        let rev   = columnText(stmt, 5)
        return StoredNote(body: body, ctime: ctime, mtime: mtime, extra: extra, path: path, rev: rev)
    }

    // MARK: - 全文検索

    /// 検索：半角／全角空白で区切った各語について「タイトル or 本文に含む」を満たし、
    /// かつ全語を満たす（AND）ノートを返す。語が1つなら従来の並び（タイトル一致が先頭）。
    func search(_ query: String) -> [NoteItem] {
        let terms = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        if terms.count == 1 { return singleTermSearch(terms[0]) }
        return andSearch(terms)
    }

    /// タイトル（ファイル名）に全語(AND)を含むノート（入力中の候補ドロップダウン用）。mtime 降順。
    func searchTitles(_ query: String) -> [NoteItem] {
        let terms = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var result: Set<String>? = nil
        for term in terms {
            let ids = titleMatchIDs(term.foldedForMatch)
            result = (result == nil) ? ids : result!.intersection(ids)
            if result!.isEmpty { return [] }
        }
        return items(forIDs: Array(result ?? []))
    }

    /// 本文に全語(AND)を含むノート（Enter 後の本文検索結果用）。mtime 降順。
    func searchBodies(_ query: String) -> [NoteItem] {
        let terms = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var result: Set<String>? = nil
        for term in terms {
            let ids = bodyMatchIDs(term)
            result = (result == nil) ? ids : result!.intersection(ids)
            if result!.isEmpty { return [] }
        }
        return items(forIDs: Array(result ?? []))
    }

    /// 1語の検索：タイトル（ファイル名）一致を先頭に、続けて本文一致を並べる。
    /// 本文一致は3文字以上で FTS5(trigram)、1〜2文字は LIKE フォールバック。
    private func singleTermSearch(_ trimmed: String) -> [NoteItem] {
        let titleHits = titleSearch(trimmed)
        let titleIDs  = Set(titleHits.map(\.id))
        let contentHits = (trimmed.count >= 3 ? ftsSearch(trimmed) : likeSearch(trimmed))
            .filter { !titleIDs.contains($0.id) }
        return titleHits + contentHits
    }

    /// 複数語の AND 検索：各語ごとに「タイトル or 本文に含む」id 集合を作り、その積集合を取る。
    /// 並びは「全語がタイトルに含まれるもの」を先頭にし、各群は mtime 降順。
    private func andSearch(_ terms: [String]) -> [NoteItem] {
        var result: Set<String>? = nil
        for term in terms {
            let ids = titleMatchIDs(term.foldedForMatch).union(bodyMatchIDs(term))
            result = (result == nil) ? ids : result!.intersection(ids)
            if result!.isEmpty { return [] }
        }
        guard let ids = result, !ids.isEmpty else { return [] }

        let items = items(forIDs: Array(ids))
        let termsLower = terms.map { $0.foldedForMatch }
        // 全語がタイトル（ファイル名）に含まれるものを優先（各群は items() の mtime 降順を保つ）
        let titleAll = items.filter { item in
            let t = item.shortTitle.foldedForMatch
            return termsLower.allSatisfy { t.contains($0) }
        }
        let titleAllIDs = Set(titleAll.map(\.id))
        let rest = items.filter { !titleAllIDs.contains($0.id) }
        return titleAll + rest
    }

    /// 単一カラム(id)の結果を Set で集める。
    private func collectIDs(_ stmt: OpaquePointer?) -> Set<String> {
        guard let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    /// 語をタイトル（ファイル名 basename）に含むノートの id 集合。termFolded は NFKC＋小文字。
    private func titleMatchIDs(_ termFolded: String) -> Set<String> {
        let stmt = prepare("SELECT id FROM notes WHERE deleted = 0 AND id_folded LIKE ? LIMIT 2000;")
        sqlite3_bind_text(stmt, 1, "%" + termFolded + "%", -1, SQLITE_TRANSIENT)
        // id にはフォルダ名も含むので、basename（末尾）に含むものだけ採用
        return collectIDs(stmt).filter {
            let base = $0.foldedForMatch.components(separatedBy: "/").last ?? $0.foldedForMatch
            return base.contains(termFolded)
        }
    }

    /// 語を本文に含むノートの id 集合。3文字以上は FTS5(trigram)、1〜2文字は LIKE。
    /// いずれも note_fts.content（索引時に NFKC 折りたたみ済み）に対して照合する。
    private func bodyMatchIDs(_ term: String) -> Set<String> {
        if term.count >= 3 {
            let phrase = "\"" + term.nfkc.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let stmt = prepare("""
            SELECT note_fts.id FROM note_fts
            JOIN notes n ON n.id = note_fts.id
            WHERE note_fts MATCH ? AND n.deleted = 0 LIMIT 2000;
            """)
            sqlite3_bind_text(stmt, 1, phrase, -1, SQLITE_TRANSIENT)
            return collectIDs(stmt)
        } else {
            let stmt = prepare("""
            SELECT note_fts.id FROM note_fts
            JOIN notes n ON n.id = note_fts.id
            WHERE note_fts.content LIKE ? AND n.deleted = 0 LIMIT 2000;
            """)
            sqlite3_bind_text(stmt, 1, "%" + term.nfkc + "%", -1, SQLITE_TRANSIENT)
            return collectIDs(stmt)
        }
    }

    /// id 群に対応する一覧アイテムを mtime 降順で取得する（IN は 900 件ずつに分割）。
    private func items(forIDs ids: [String]) -> [NoteItem] {
        guard !ids.isEmpty else { return [] }
        var all: [NoteItem] = []
        var index = 0
        while index < ids.count {
            let end = min(index + 900, ids.count)
            let chunk = Array(ids[index..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT id, path, mtime, substr(content, 1, 400)
            FROM notes
            WHERE deleted = 0 AND id IN (\(placeholders))
            ORDER BY mtime DESC;
            """
            if let stmt = prepare(sql) {
                for (i, id) in chunk.enumerated() {
                    sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT)
                }
                all.append(contentsOf: readItems(stmt, previewTrim: true))
            }
            index = end
        }
        // チャンクをまたぐので全体で mtime 降順に整え、上限200件
        return Array(all.sorted { ($0.mtime ?? 0) > ($1.mtime ?? 0) }.prefix(200))
    }

    /// タイトル（ファイル名）に語句を含むノート。id_folded で粗く絞り、basename で厳密判定。
    private func titleSearch(_ query: String) -> [NoteItem] {
        let sql = """
        SELECT id, path, mtime, substr(content, 1, 400)
        FROM notes
        WHERE deleted = 0 AND id_folded LIKE ?
        ORDER BY mtime DESC
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        let q = query.foldedForMatch
        sqlite3_bind_text(stmt, 1, "%" + q + "%", -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: true).filter { $0.shortTitle.foldedForMatch.contains(q) }
    }

    private func ftsSearch(_ query: String) -> [NoteItem] {
        // trigram では語をフレーズ（"..."）として渡すと部分一致になる。" は "" でエスケープ。
        // note_fts.content は索引時に NFKC 折りたたみ済みなので、検索語も同じく折りたたむ。
        let phrase = "\"" + query.nfkc.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
        SELECT n.id, n.path, n.mtime, substr(note_fts.content, 1, 400)
        FROM note_fts
        JOIN notes n ON n.id = note_fts.id
        WHERE note_fts.content LIKE ? AND n.deleted = 0
        ORDER BY n.mtime DESC
        LIMIT 200;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%" + query.nfkc + "%", -1, SQLITE_TRANSIENT)
        return readItems(stmt, previewTrim: true)
    }

    /// カード表示用：本文先頭にあるリモート画像（https）のURLを返す。無ければ nil。
    func firstImageURL(forID id: String) -> String? {
        guard let stmt = prepare("SELECT content FROM notes WHERE id = ? AND deleted = 0;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let content = columnText(stmt, 0) else { return nil }
        return Self.firstImageURL(in: content)
    }

    /// Markdown 画像記法 `![alt](https://…)` の最初の URL を取り出す。
    static func firstImageURL(in body: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\((https?://[^)\s]+)\)"#) else {
            return nil
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = re.firstMatch(in: body, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[r])
    }

    // MARK: - バックアップ用エクスポート

    /// バックアップ対象ノートを (リポジトリ内パス, 全文) で列挙する。
    /// - folder: nil=全体（path をそのまま）／値あり=そのフォルダのみ（フォルダ名を外して直下に）
    func notesForBackup(folder: String?) -> [(path: String, content: String)] {
        let base = "SELECT path, ctime, mtime, content, frontmatter_extra FROM notes WHERE deleted = 0"
        let sql  = folder == nil ? base + ";" : base + " AND id LIKE ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        let dropCount: Int
        if let folder {
            sqlite3_bind_text(stmt, 1, folder.lowercased() + "/%", -1, SQLITE_TRANSIENT)
            dropCount = folder.split(separator: "/").count
        } else {
            dropCount = 0
        }

        var result: [(path: String, content: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let path = columnText(stmt, 0) else { continue }
            let ctime = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
            let mtime = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let body  = columnText(stmt, 3) ?? ""
            let extraRaw = columnText(stmt, 4) ?? ""
            let extra = extraRaw.isEmpty ? [] : extraRaw.components(separatedBy: "\n")

            let now = Date().timeIntervalSince1970 * 1000
            let createdSec = Int((ctime ?? mtime ?? now) / 1000)
            let updatedSec = Int((mtime ?? now) / 1000)
            let content = FrontmatterParser.compose(
                createdSec: createdSec, updatedSec: updatedSec, extra: extra, body: body
            )

            let repoPath: String
            if dropCount > 0 {
                let comps = path.components(separatedBy: "/")
                repoPath = comps.count > dropCount ? comps.dropFirst(dropCount).joined(separator: "/") : path
            } else {
                repoPath = path
            }
            // Netlify 等はファイル名の # / ? を許可しないため全角に置換（公開ファイル名のみ）
            let safePath = repoPath
                .replacingOccurrences(of: "#", with: "＃")
                .replacingOccurrences(of: "?", with: "？")
            result.append((safePath, content))
        }
        return result
    }

    // MARK: - バックリンク

    /// この id を指している（リンク元の）ノート一覧。
    /// 解決規則は本文タップと同じ：フルパス一致 または ファイル名（basename）一致（小文字）。
    func backlinks(for id: String) -> [NoteItem] {
        let lower = id.foldedForMatch
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

    /// 2ホップリンク：このノートの発リンク先（出現順）ごとに、
    /// 「同じリンク先へリンクしている他のノート」をまとめて返す。
    /// - excludingIDs: 除外する id（自分自身＋直接バックリンクなど、既に表示済みのもの）
    func twoHopGroups(for id: String, excludingIDs: Set<String>) -> [TwoHopGroup] {
        guard let body = content(id) else { return [] }

        // 発リンクキーを本文の出現順で（重複除去）
        guard let regex = Self.wikiLinkRegex else { return [] }
        let ns = body as NSString
        var orderedKeys: [String] = []
        var seen = Set<String>()
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2,
                  let key = Self.normalizeKey(ns.substring(with: m.range(at: 1))),
                  seen.insert(key).inserted else { continue }
            orderedKeys.append(key)
        }
        guard !orderedKeys.isEmpty else { return [] }

        var groups: [TwoHopGroup] = []
        for key in orderedKeys {
            // 同じキーへリンクしている他のノート（自分は除外）
            let sql = """
            SELECT DISTINCT n.id, n.path, n.mtime, substr(n.content, 1, 400)
            FROM links l
            JOIN notes n ON n.id = l.source_id
            WHERE l.target_key = ? AND n.deleted = 0 AND n.id != ?
            ORDER BY n.mtime DESC
            LIMIT 50;
            """
            var notes: [NoteItem] = []
            if let stmt = prepare(sql) {
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, id,  -1, SQLITE_TRANSIENT)
                notes = readItems(stmt, previewTrim: true)
                sqlite3_finalize(stmt)
            }
            notes.removeAll { excludingIDs.contains($0.id) }

            // リンク先キー → 実ノートの解決（フルパス一致 or ファイル名一致。バックリンクと同じ規則）
            let target = resolveNote(forKey: key)
            // 表示する意味のあるグループだけ（リンク先が実在する、または他にリンク元がある）
            guard target != nil || !notes.isEmpty else { continue }
            groups.append(TwoHopGroup(
                targetKey: key,
                targetTitle: target?.shortTitle ?? key,
                targetId: target?.id,
                notes: notes
            ))
        }
        return groups
    }

    /// 全ノートの [[...]] に登場するリンク先キー（正規化済み・重複なし）。
    /// 未作成ページのサジェスト（Cosense/Obsidian 風）用。
    func allLinkTargetKeys() -> [String] {
        guard let stmt = prepare("SELECT DISTINCT target_key FROM links ORDER BY target_key;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// 他アプリ共有用リンク索引を、トップレベルフォルダ単位のグループに分けて返す。
    /// 各グループがそのまま CouchDB 上の1文書になる（フォルダ別インデックス）。
    /// - 実在ノート（exists=true）: そのフォルダのノート名。path に `_id`（小文字）を入れる。
    /// - 未作成ページ（exists=false）: そのフォルダのノートが `[[...]]` 言及するキーのうち、
    ///   ローカルに実在しないもの。実在判定はローカル全体で行う（別フォルダの実在ノートを
    ///   誤って「未作成」にしない。読み手側もマージ時に exists=true を優先する）。
    /// すべてローカル SQLite（同期スコープ分）から作るので軽量。
    func linkIndexByFolder() -> [LinkIndexFolderGroup] {
        var existingKeys = Set<String>()   // ローカル全体の実在キー（id キー・タイトルキー）
        var groupKeys = Set<String>()
        var displayByGroup: [String: String] = [:]
        var existingByGroup: [String: [LinkIndexEntry]] = [:]
        var seenTitleByGroup: [String: Set<String>] = [:]
        var mentionedByGroup: [String: [LinkIndexEntry]] = [:]
        var seenMentionByGroup: [String: Set<String>] = [:]

        for n in listItems() {
            var idKey = n.id.foldedForMatch
            if idKey.hasSuffix(".md") { idKey = String(idKey.dropLast(3)) }
            existingKeys.insert(idKey)
            let title = n.shortTitle
            let titleKey = title.foldedForMatch
            existingKeys.insert(titleKey)
            let (gk, disp) = Self.topLevelFolder(n.path ?? n.id)
            groupKeys.insert(gk)
            if let disp, displayByGroup[gk] == nil { displayByGroup[gk] = disp }
            if seenTitleByGroup[gk, default: []].insert(titleKey).inserted {
                // path は文書の path フィールド（大小保持）ではなく _id（小文字）をそのまま入れる。
                existingByGroup[gk, default: []].append(
                    LinkIndexEntry(key: titleKey, title: title, path: n.id.lowercased(), exists: true))
            }
        }

        for (sourceID, targetKey, display) in linkPairs() where !existingKeys.contains(targetKey) {
            let (gk, _) = Self.topLevelFolder(sourceID)
            groupKeys.insert(gk)
            if seenMentionByGroup[gk, default: []].insert(targetKey).inserted {
                // title は原文（大小保持）。移行前の行など原文が無ければキー（小文字）で代替。
                let title = (display?.isEmpty == false) ? display! : targetKey
                mentionedByGroup[gk, default: []].append(
                    LinkIndexEntry(key: targetKey, title: title, path: nil, exists: false))
            }
        }

        return groupKeys.map { gk in
            LinkIndexFolderGroup(
                groupKey: gk,
                folder: displayByGroup[gk],
                entries: (existingByGroup[gk] ?? []) + (mentionedByGroup[gk] ?? [])
            )
        }
    }

    /// links テーブルの (リンク元 id, リンク先キー・小文字, 表示用原文) の全ペア。
    private func linkPairs() -> [(String, String, String?)] {
        guard let stmt = prepare("SELECT source_id, target_key, target_display FROM links;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = columnText(stmt, 0) ?? ""
            let t = columnText(stmt, 1) ?? ""
            let d = columnText(stmt, 2)
            if !s.isEmpty && !t.isEmpty { out.append((s, t, d)) }
        }
        return out
    }

    /// id/path のトップレベルフォルダを返す。"/" が無ければルート（groupKey="" / display=nil）。
    /// groupKey は照合・文書 ID 用に小文字、display は表示用に大小保持。
    private static func topLevelFolder(_ idOrPath: String) -> (groupKey: String, display: String?) {
        guard let slash = idOrPath.firstIndex(of: "/") else { return ("", nil) }
        let top = String(idOrPath[..<slash])
        return (top.lowercased(), top)
    }

    /// 正規化キー（NFKC＋小文字・.md 除去）から生存ノートを解決する。フルパス一致を優先し、次に basename 一致。
    private func resolveNote(forKey key: String) -> NoteItem? {
        let sql = """
        SELECT id, path FROM notes
        WHERE deleted = 0 AND (id_folded = ? OR id_folded LIKE ?)
        ORDER BY (id_folded = ?) DESC, mtime DESC
        LIMIT 1;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        let exact = key + ".md"
        sqlite3_bind_text(stmt, 1, exact, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, "%/" + exact, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, exact, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let idC = sqlite3_column_text(stmt, 0) else { return nil }
        return NoteItem(id: String(cString: idC), path: columnText(stmt, 1))
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

    /// 1 件を upsert（サーバ確定＝clean。ctime は新規時のみ設定し、更新時は保持）。
    func upsert(_ r: NoteRecord) {
        upsert(r, on: db, state: "clean")
    }

    /// 複数件を 1 トランザクションで一括 upsert（初回インポート用。サーバ確定＝clean）。
    func upsertMany(_ records: [NoteRecord]) {
        guard !records.isEmpty else { return }
        exec("BEGIN TRANSACTION;")
        for r in records { upsert(r, on: db, state: "clean") }
        exec("COMMIT;")
    }

    /// ローカル編集を未同期（dirty）として永続化する。kill されても残り、後で同期ワーカが押し上げる。
    func saveDirty(_ r: NoteRecord) {
        upsert(r, on: db, state: "dirty")
    }

    /// 同期成功後、clean に戻す（内容は変えない）。rev を渡せば基準 rev も更新する。
    func markClean(_ id: String, rev: String? = nil) {
        let sql = rev == nil
            ? "UPDATE notes SET sync_state = 'clean' WHERE id = ?;"
            : "UPDATE notes SET sync_state = 'clean', rev = ? WHERE id = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        if let rev {
            sqlite3_bind_text(stmt, 1, rev, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }

    /// 削除予定（pendingDelete）にする。一覧・検索からは隠すが、行・本文は残してサーバ削除の押し上げに備える。
    func markPendingDelete(_ id: String) {
        guard let stmt = prepare("UPDATE notes SET deleted = 1, sync_state = 'pendingDelete' WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        deleteFTS(id)
        deleteLinks(id)
    }

    /// サーバ削除が確定したノートを物理的に行ごと消す。
    func removeRow(_ id: String) {
        if let stmt = prepare("DELETE FROM notes WHERE id = ?;") {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        deleteFTS(id)
        deleteLinks(id)
    }

    /// 未同期（dirty）ノートの id 集合（同期ワーカの押し上げ対象・リコンシリエーションの保護対象）。
    func dirtyIDs() -> Set<String> {
        guard let stmt = prepare("SELECT id FROM notes WHERE sync_state = 'dirty' AND deleted = 0;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    /// 削除予定（pendingDelete）の id 集合（同期ワーカの削除対象・リコンシリエーションの保護対象）。
    func pendingDeleteIDs() -> Set<String> {
        guard let stmt = prepare("SELECT id FROM notes WHERE sync_state = 'pendingDelete';") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
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

    private func upsert(_ r: NoteRecord, on db: OpaquePointer?, state: String) {
        // フロントマターを分離し、本文のみを保存（表示・検索・プレビューを綺麗に保つ）
        let parsed = FrontmatterParser.split(r.content)
        let body   = parsed.body
        let extra  = parsed.extraLines.joined(separator: "\n")
        let pin    = FrontmatterParser.extractPin(from: parsed.extraLines)

        // rev は新しい値があればそれを採用し、無ければ（ローカル書き込み等）既存値を保持する。
        let sql = """
        INSERT INTO notes (id, path, mtime, ctime, size, content, frontmatter_extra, rev, sync_state, pin, id_folded, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            mtime = excluded.mtime,
            size = excluded.size,
            content = excluded.content,
            frontmatter_extra = excluded.frontmatter_extra,
            rev = COALESCE(excluded.rev, rev),
            sync_state = excluded.sync_state,
            pin = excluded.pin,
            id_folded = excluded.id_folded,
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
        bindOptionalText(stmt, 8, r.rev)
        sqlite3_bind_text(stmt, 9, state, -1, SQLITE_TRANSIENT)
        if let pin { sqlite3_bind_int64(stmt, 10, Int64(pin)) } else { sqlite3_bind_null(stmt, 10) }
        sqlite3_bind_text(stmt, 11, r.id.foldedForMatch, -1, SQLITE_TRANSIENT)
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
        // NFKC で折りたたんでから索引する（全角/半角の不一致で検索漏れが起きるのを防ぐ）。
        sqlite3_bind_text(stmt, 2, content.nfkc, -1, SQLITE_TRANSIENT)
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
    /// 本文中の [[...]] を (key, display) の配列にする（同一ノート内は key で重複除去・先出優先）。
    /// key=照合用の小文字キー、display=挿入・表示用の原文（大小保持）。
    private static func parseLinkPairs(from content: String) -> [(key: String, display: String)] {
        guard let regex = wikiLinkRegex else { return [] }
        let ns = content as NSString
        var seen = Set<String>()
        var out: [(key: String, display: String)] = []
        for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2,
                  let p = linkParts(ns.substring(with: m.range(at: 1))) else { continue }
            if seen.insert(p.key).inserted { out.append(p) }
        }
        return out
    }

    /// リンク表記を「照合用キー（小文字）」と「表示用原文（大小保持）」に分解する。
    /// いずれも別名`|`・見出し`#`除去、前後空白トリム、`.md` 除去、前後 `/ ` トリム。小文字化の有無だけが違う。
    private static func linkParts(_ raw: String) -> (key: String, display: String)? {
        var s = raw
        if let bar  = s.firstIndex(of: "|") { s = String(s[..<bar]) }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasSuffix(".md") { s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return s.isEmpty ? nil : (s.foldedForMatch, s)
    }

    /// リンク表記を比較用キーに正規化（エイリアス/見出し除去・小文字・.md 除去）。
    private static func normalizeKey(_ raw: String) -> String? {
        return linkParts(raw)?.key
    }

    private func linksCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM links;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func updateLinks(id: String, content: String) {
        deleteLinks(id)
        let pairs = Self.parseLinkPairs(from: content)
        guard !pairs.isEmpty,
              let stmt = prepare("INSERT INTO links (source_id, target_key, target_display) VALUES (?, ?, ?);")
        else { return }
        defer { sqlite3_finalize(stmt) }
        for p in pairs {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id,          -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, p.key,       -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, p.display,   -1, SQLITE_TRANSIENT)
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

    /// notes.id_folded（id の NFKC＋小文字化コピー）を全行バックフィルする。
    private func backfillIDFolded() {
        var ids: [String] = []
        if let stmt = prepare("SELECT id FROM notes;") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
        }
        exec("BEGIN TRANSACTION;")
        if let stmt = prepare("UPDATE notes SET id_folded = ? WHERE id = ?;") {
            for id in ids {
                sqlite3_bind_text(stmt, 1, id.foldedForMatch, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
    }

    /// note_fts を全ノートの本文（NFKC 折りたたみ済み）から作り直す（全角/半角修正の移行用）。
    private func rebuildFTSFolded() {
        var rows: [(String, String)] = []
        if let stmt = prepare("SELECT id, content FROM notes WHERE deleted = 0;") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((columnText(stmt, 0) ?? "", columnText(stmt, 1) ?? ""))
            }
            sqlite3_finalize(stmt)
        }
        exec("BEGIN TRANSACTION;")
        exec("DELETE FROM note_fts;")
        if let stmt = prepare("INSERT INTO note_fts (id, content) VALUES (?, ?);") {
            for (id, content) in rows {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, content.nfkc, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
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
