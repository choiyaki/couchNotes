//
//  BackupTarget.swift
//  couchNotes
//
//  GitHub バックアップ先（フォルダ→リポジトリ）の設定。複数登録可。
//  トークンは Keychain、その他は UserDefaults に保存する。
//

import Foundation

struct BackupTarget: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var folder: String? = nil     // nil = 全体（ルート含む全ノート）。値あり = そのフォルダのみ
    var owner: String = ""
    var repo: String = ""
    var branch: String = "main"
    var lastBackup: Date? = nil
}

enum BackupStore {
    private static let key = "backupTargets"

    static var targets: [BackupTarget] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let arr = try? JSONDecoder().decode([BackupTarget].self, from: data) else { return [] }
            return arr
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func upsert(_ target: BackupTarget) {
        var arr = targets
        if let i = arr.firstIndex(where: { $0.id == target.id }) { arr[i] = target }
        else { arr.append(target) }
        targets = arr
    }

    static func remove(_ id: UUID) {
        targets = targets.filter { $0.id != id }
        KeychainManager.shared.delete(key: tokenKey(id))
    }

    // MARK: - トークン（Keychain）

    private static func tokenKey(_ id: UUID) -> String { "github_token_\(id.uuidString)" }
    static func token(for id: UUID) -> String? { KeychainManager.shared.load(key: tokenKey(id)) }
    static func setToken(_ token: String, for id: UUID) {
        if token.isEmpty { KeychainManager.shared.delete(key: tokenKey(id)) }
        else { KeychainManager.shared.save(key: tokenKey(id), value: token) }
    }
}
