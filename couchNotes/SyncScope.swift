//
//  SyncScope.swift
//  couchNotes
//
//  同期対象の範囲（フォルダ許可リスト）を管理する。
//  ルート直下のノートは常に同期し、加えて指定フォルダ配下を同期する。
//

import Foundation

extension Notification.Name {
    /// 同期フォルダの追加／削除があった。userInfo["added"], userInfo["removed"] に正規化済みフォルダ名配列。
    static let syncScopeDidChange = Notification.Name("couchNotes.syncScopeDidChange")
}

enum SyncScope {
    private static let key = "syncedFolders"

    /// 設定された同期フォルダ（保存されている生の値）
    static var folders: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 比較用の正規化：小文字化・前後の空白／スラッシュ除去
    static func normalize(_ folder: String) -> String {
        folder.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 正規化済み・重複排除済みのフォルダ一覧
    static var normalizedFolders: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for f in folders {
            let n = normalize(f)
            guard !n.isEmpty, !seen.contains(n) else { continue }
            seen.insert(n)
            result.append(n)
        }
        return result
    }

    /// フォルダを追加（重複は無視）。実際に追加されたら正規化名を返す。
    @discardableResult
    static func add(_ folder: String) -> String? {
        let n = normalize(folder)
        guard !n.isEmpty else { return nil }
        var current = normalizedFolders
        guard !current.contains(n) else { return nil }
        current.append(n)
        folders = current
        return n
    }

    /// フォルダを削除。実際に削除されたら true。
    @discardableResult
    static func remove(_ folder: String) -> Bool {
        let n = normalize(folder)
        var current = normalizedFolders
        guard let idx = current.firstIndex(of: n) else { return false }
        current.remove(at: idx)
        folders = current
        return true
    }

    /// この id を同期対象とすべきか。
    /// ルート直下（"/" を含まない）は常に true、それ以外は許可フォルダ配下なら true。
    /// - Parameter folders: 判定に使う正規化済みフォルダ（省略時は現在の設定）
    static func shouldSync(id: String, folders: [String]? = nil) -> Bool {
        let lid = id.lowercased()
        if !lid.contains("/") { return true }
        let list = folders ?? normalizedFolders
        for f in list where lid.hasPrefix(f + "/") { return true }
        return false
    }
}
