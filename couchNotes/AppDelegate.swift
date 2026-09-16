//
//  AppDelegate.swift
//  couchNotes
//
//  ホーム画面のアイコン長押しメニュー（Info.plist の UIApplicationShortcutItems）を受け取る。
//  SwiftUI の App には受け口が無いので、シーンデリゲートで受けて URL スキームと同じ処理へ回す。
//

import UIKit

/// ホーム画面メニューの種類 → 対応する couchnotes:// URL
enum HomeScreenShortcut {
    static let handwriteType = "com.github.choiyaki.couchNotes.handwrite"

    static func url(for item: UIApplicationShortcutItem) -> URL? {
        switch item.type {
        case handwriteType: return URL(string: "couchnotes://handwrite")
        default: return nil
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShortcutSceneDelegate.self
        return config
    }
}

final class ShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// 起動していない状態でメニューから開かれた場合
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { perform(item) }
    }

    /// 起動済み（バックグラウンド）でメニューから開かれた場合
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(perform(shortcutItem))
    }

    @discardableResult
    private func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let url = HomeScreenShortcut.url(for: item) else { return false }
        Task { @MainActor in URLActionRouter.shared.handle(url) }
        return true
    }
}
