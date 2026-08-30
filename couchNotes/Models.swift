import Foundation

// MARK: - CouchDB LiveSync 形式

struct LiveSyncNote: Codable {
    var _id: String
    var _rev: String?
    var children: [String]
    var path: String
    var ctime: Double
    var mtime: Double
    var size: Int
    var type: String
    var eden: [String: String]?
    var deleted: Bool?            // 旧ソフト削除マーカー（移行前の既存文書を隠すための読み取り専用。新規削除はネイティブ削除を使う）

    init(id: String, children: [String], size: Int, ctime: Double? = nil) {
        let now = Date().timeIntervalSince1970 * 1000
        self._id      = id
        self._rev     = nil
        self.children = children
        self.path     = id
        self.ctime    = ctime ?? now
        self.mtime    = now
        self.size     = size
        self.type     = "plain"
        self.eden     = [:]
        self.deleted  = nil
    }
}

struct LiveSyncChunk: Codable {
    var _id: String
    var _rev: String?
    var data: String
    var type: String = "leaf"
}

// MARK: - Mango クエリレスポンス（_find）

struct MangoResponse: Decodable {
    struct NoteDoc: Decodable {
        let id: String
        let mtime: Double?
        let path: String?   // 元のファイルパス（大文字小文字を保持）
        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case mtime
            case path
        }
    }
    let docs: [NoteDoc]
}

// MARK: - ノート一覧アイテム

struct NoteItem: Identifiable {
    let id: String        // CouchDB _id（小文字に正規化済み）
    let mtime: Double?    // CouchDB の mtime（ミリ秒）
    let path: String?     // 元のファイルパス（大文字小文字を保持）
    let preview: String?  // 一覧用の本文プレビュー（SQLite から読み出し済み）
    let pin: Int?         // ピン留め番号（フロントマターの pin: N。小さいほど上位）

    init(id: String, mtime: Double? = nil, path: String? = nil, preview: String? = nil, pin: Int? = nil) {
        self.id      = id
        self.mtime   = mtime
        self.path    = path
        self.preview = preview
        self.pin     = pin
    }

    /// 最終更新日時（Date型）
    var lastModified: Date? {
        guard let mtime else { return nil }
        return Date(timeIntervalSince1970: mtime / 1000)
    }

    /// yyyyMMdd 形式のデイリーノートなら Date に変換
    var parsedDate: Date? {
        let s = String(id.prefix(8))
        guard s.count == 8, s.allSatisfy({ $0.isNumber }) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        return df.date(from: s)
    }

    /// リスト表示用タイトル
    var shortTitle: String {
        let displayId = path ?? id
        return displayId.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "") ?? displayId
    }

    /// リスト表示用サブタイトル（最終更新日時, yyyyMMdd HH:mm）
    var lastModifiedString: String {
        guard let date = lastModified else { return id }
        return DateDisplay.ymdhm.string(from: date)
    }

    var isToday: Bool {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        return id == "\(df.string(from: Date())).md"
    }
}

// MARK: - 2ホップリンク

/// 「このノートの発リンク先」1つぶんのグループ。
/// notes には同じリンク先へリンクしている他のノート（自分と直接バックリンクを除く）が入る。
struct TwoHopGroup {
    let targetKey: String     // 正規化キー（小文字・.md 除去）
    let targetTitle: String   // 表示名（解決できたらそのノートのタイトル、なければキー原文）
    let targetId: String?     // 解決できたノートの id（タップで開く用。nil = 未作成ページ）
    let notes: [NoteItem]
}

// MARK: - 永続化用レコード（本文込み）

/// SQLite に保存する 1 ノート分の完全な情報（content はフロントマター込みの全文）。
struct NoteRecord {
    let id: String
    let path: String?
    let mtime: Double?
    let ctime: Double?
    let size: Int
    let content: String
    var rev: String? = nil   // CouchDB の _rev（リコンシリエーションの世代比較用。ローカル書き込み時は nil）
}

/// エディタ用に取り出したノート（body はフロントマター除去済み）。
struct StoredNote {
    let body: String
    let ctime: Double?    // 作成時刻（ms）
    let mtime: Double?    // 更新時刻（ms）
    let extra: String?    // created/updated 以外のフロントマター行
    let path: String?     // 元のパス（大小保持）
    var rev: String? = nil   // 同期の基準 _rev（楽観ロック用。未取得は nil）
}

// MARK: - テキスト正規化（検索・リンクキー照合用）

extension String {
    /// NFKC 正規化のみ（大小文字はそのまま）。
    /// 全角英数・記号・スペース（"Ａ"→"A"、"　"→" " など）を半角と同一視できるようにする。
    /// FTS5(trigram) の索引・検索語はこちらを使う（大小文字は trigram 側が別途吸収するため、
    /// ここで潰すとスニペット表示の大文字/小文字まで変わってしまう）。
    var nfkc: String {
        precomposedStringWithCompatibilityMapping
    }

    /// 検索・リンクキーの突き合わせ用に NFKC 正規化＋小文字化する。
    /// id/タイトルの完全一致・LIKE 照合（SQLite の `=`／既定の LIKE は大文字小文字だけ吸収するため
    /// 全角/半角は別途揃える必要がある）に使う。表示用の文字列には使わない。
    var foldedForMatch: String {
        nfkc.lowercased()
    }
}

// MARK: - 新規ノートの命名

enum NoteNaming {
    /// タイトルとフォルダ（nil=ルート）から (_id, path) を作る。
    /// _id は小文字、path は大小保持。"/" はフォルダ誤生成を防ぐため "-" に置換。
    static func make(title: String, folder: String?) -> (id: String, path: String)? {
        let safe = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !safe.isEmpty else { return nil }
        let displayFilename = safe + ".md"
        let idFilename      = displayFilename.lowercased()
        // _id はフォルダも小文字、path はフォルダ原文（Obsidian の実フォルダ名）
        let id   = folder.map { "\($0.lowercased())/\(idFilename)" } ?? idFilename
        let path = folder.map { "\($0)/\(displayFilename)" }         ?? displayFilename
        return (id, path)
    }
}

// MARK: - エラー

enum CouchDBError: LocalizedError {
    case invalidSettings
    case networkError(Error)
    case httpError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "設定が不完全です。設定画面を確認してください。"
        case .networkError(let e):
            return "ネットワークエラー: \(e.localizedDescription)"
        case .httpError(let code, let msg):
            return "サーバーエラー (\(code)): \(msg)"
        case .decodingError:
            return "レスポンスの解析に失敗しました。"
        }
    }
}
