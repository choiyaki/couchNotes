//
//  ShareExtensionToken.swift
//  couchNotes
//
//  共有シートの拡張機能（couchNotesShare）に、couchimg のアップロード専用トークンの写しを渡す。
//  拡張機能は本体の Keychain を読めないので、両方が読める共有の置き場（Keychain の共有グループ）に置く。
//  置くのは upload のトークンだけ。閲覧用（app）・管理用（admin）・CouchDB のパスワードは本体だけの置き場のまま。
//

import Foundation
import Security

enum ShareExtensionToken {
    // 拡張機能側（couchNotesShare/ShareViewController.swift の ShareUploader）と同じ値にする
    static let accessGroup = "H8BCFLBJVR.com.github.choiyaki.couchNotes.shared"
    static let service = "com.github.choiyaki.couchNotes.share"
    static let account = "couchimg_upload_token"

#if targetEnvironment(macCatalyst)
    /// Mac 版には拡張機能がない
    static func sync(_ token: String?) {}
#else
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// 共有の置き場を、本体の今の登録に合わせる（token が nil なら消す）。
    static func sync(_ token: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        // 端末のバックアップや新しい端末への移行に載せない（本体のトークンと同じ扱い）
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            syncLog.error("共有シート用のトークンを置けなかった status=\(status)")
        }
    }
#endif
}
