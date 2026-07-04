import Foundation
import Security

/// 接続情報（CouchDB のホスト／DB／ユーザ／パスワード）の保存先。
/// - iOS: データ保護 Keychain に安全に保存する。
/// - Mac Catalyst: サンドボックス下の Keychain は署名プロファイルへの Keychain Sharing
///   capability 登録を要求し（errSecMissingEntitlement -34018）保存に失敗するため、
///   UserDefaults に保存する（自己ホストの個人利用向けの割り切り）。
class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    private let service = "com.yourapp.dailynote"

#if targetEnvironment(macCatalyst)

    private let defaultsPrefix = "cred_"
    private func defaultsKey(_ key: String) -> String { defaultsPrefix + key }

    @discardableResult
    func save(key: String, value: String) -> Bool {
        UserDefaults.standard.set(value, forKey: defaultsKey(key))
        return true
    }

    func load(key: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(key))
    }

    func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(key))
    }

#else

    /// キー1件分の基本クエリ。`kSecUseDataProtectionKeychain` で iOS のデータ保護 Keychain を使う。
    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              service,
            kSecAttrAccount as String:              key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// 保存に成功したら true。失敗時は OSStatus をログに残す（無言失敗を避ける）。
    @discardableResult
    func save(key: String, value: String) -> Bool {
        let data = value.data(using: .utf8)!
        SecItemDelete(baseQuery(key: key) as CFDictionary)
        var attributes = baseQuery(key: key)
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            syncLog.error("Keychain 保存に失敗 key=\(key, privacy: .public) status=\(status)")
        }
        return status == errSecSuccess
    }

    func load(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    func delete(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

#endif
}
