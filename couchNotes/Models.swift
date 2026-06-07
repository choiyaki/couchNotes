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
    var deleted: Bool?            // LiveSync 互換のソフト削除マーカー（未削除時は nil＝出力されない）

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

    init(id: String, mtime: Double? = nil, path: String? = nil, preview: String? = nil) {
        self.id      = id
        self.mtime   = mtime
        self.path    = path
        self.preview = preview
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

// MARK: - 永続化用レコード（本文込み）

/// SQLite に保存する 1 ノート分の完全な情報（content はフロントマター込みの全文）。
struct NoteRecord {
    let id: String
    let path: String?
    let mtime: Double?
    let ctime: Double?
    let size: Int
    let content: String
}

/// エディタ用に取り出したノート（body はフロントマター除去済み）。
struct StoredNote {
    let body: String
    let ctime: Double?    // 作成時刻（ms）
    let mtime: Double?    // 更新時刻（ms）
    let extra: String?    // created/updated 以外のフロントマター行
    let path: String?     // 元のパス（大小保持）
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
