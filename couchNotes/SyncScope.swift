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

    /// 正規化：前後の空白／スラッシュ除去（大文字小文字は保持＝path に使うため）。
    static func normalize(_ folder: String) -> String {
        folder.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 正規化済み・重複排除済みのフォルダ一覧（大小は保持、重複判定のみ小文字）
    static var normalizedFolders: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for f in folders {
            let n = normalize(f)
            let key = n.lowercased()
            guard !n.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(n)
        }
        return result
    }

    /// フォルダを追加（大小無視で重複なら無視）。追加されたら原文を返す。
    @discardableResult
    static func add(_ folder: String) -> String? {
        let n = normalize(folder)
        guard !n.isEmpty else { return nil }
        let key = n.lowercased()
        var current = normalizedFolders
        guard !current.contains(where: { $0.lowercased() == key }) else { return nil }
        current.append(n)
        folders = current
        return n
    }

    /// フォルダを削除（大小無視）。削除されたら true。
    @discardableResult
    static func remove(_ folder: String) -> Bool {
        let key = normalize(folder).lowercased()
        var current = normalizedFolders
        guard let idx = current.firstIndex(where: { $0.lowercased() == key }) else { return false }
        current.remove(at: idx)
        folders = current
        return true
    }

    /// この id を同期対象とすべきか。
    /// ルート直下（"/" を含まない）は常に true、それ以外は許可フォルダ配下なら true。
    /// 照合は小文字で行う（_id は小文字のため）。
    /// - Parameter folders: 判定に使うフォルダ（省略時は現在の設定）
    static func shouldSync(id: String, folders: [String]? = nil) -> Bool {
        let lid = id.lowercased()
        if !lid.contains("/") { return true }
        let list = (folders ?? normalizedFolders).map { $0.lowercased() }
        for f in list where lid.hasPrefix(f + "/") { return true }
        return false
    }
}
