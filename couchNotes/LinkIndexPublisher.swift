//
//  LinkIndexPublisher.swift
//  couchNotes
//
//  リンクサジェスト索引を CouchDB に1文書（予約ID couchnotes_linkindex）として書き出す。
//  他アプリはこの文書を GET して同じサジェストを再現できる（docs/link-index.md 参照）。
//
//  省コスト設計:
//    - .noteStoreDidChange（push 完了・longpoll 取り込み・reconcile で発火）を単一フックにする。
//    - デバウンスして連続変更をまとめる。
//    - 索引集合のフィンガープリント（SHA256）を前回と比較し、変化した時だけ PUT する。
//      → 通常のタイピングでは集合が変わらず、ネットワーク書き込みは発生しない。
//    - 生成は actor NoteStore 上（非メイン・直列化）で走るので UI を塞がない。
//

import Foundation
import CryptoKit

@MainActor
final class LinkIndexPublisher {
    static let shared = LinkIndexPublisher()
    private init() {}

    private var started = false
    private var observerToken: NSObjectProtocol?
    private var debounce: Task<Void, Never>?

    /// 前回アップロードしたフィンガープリントを保存する UserDefaults キーの接頭辞
    /// （フォルダごとに ".{groupKey}" を付けて保存し、変化したフォルダだけ書き直す）。
    private let fingerprintKey = "couchNotes.linkIndexFingerprint"

    /// アプリ起動時に一度呼ぶ。以後 .noteStoreDidChange を監視して自動更新する。
    func start() {
        guard !started else { return }
        started = true
        observerToken = NotificationCenter.default.addObserver(
            forName: .noteStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            // MainActor に確実に載せてからスケジュール（通知は main queue だが明示的に）。
            Task { @MainActor in self?.schedule(after: .seconds(5)) }
        }
        schedule(after: .seconds(3))   // 起動直後のバックフィル
    }

    private func schedule(after delay: Duration) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.publishIfChanged()
        }
    }

    private func publishIfChanged() async {
        guard NetworkMonitor.shared.isOnline else { return }
        await cleanupLegacyIfNeeded()

        let groups = await NoteStore.shared.linkIndexByFolder()
        // 空（初回インポート途中や真に空の DB）はサーバの既存索引を潰さないよう書かない。
        guard !groups.isEmpty else { return }

        let generatedAt = ISO8601DateFormatter().string(from: Date())
        for g in groups {
            let fingerprint = Self.fingerprint(of: g.entries)
            let key = fingerprintKey + "." + (g.groupKey.isEmpty ? "root" : g.groupKey)
            if fingerprint == UserDefaults.standard.string(forKey: key) { continue }
            do {
                try await CouchDBClient.shared.saveLinkIndex(
                    groupKey: g.groupKey, folder: g.folder,
                    entries: g.entries, generatedAt: generatedAt)
                UserDefaults.standard.set(fingerprint, forKey: key)
            } catch {
                // オフライン・未設定・一時失敗は据え置き。次の .noteStoreDidChange で再試行する。
            }
        }
    }

    /// 旧・単一索引文書（couchnotes_linkindex）をフォルダ別方式へ移行時に1回だけ削除。
    private func cleanupLegacyIfNeeded() async {
        let flag = "couchNotes.linkIndexLegacyCleaned"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        do {
            try await CouchDBClient.shared.deleteDocIfExists(id: "couchnotes_linkindex")
            UserDefaults.standard.set(true, forKey: flag)   // 成功時のみ完了印（失敗は次回再試行）
        } catch {
            // オフライン等。次回に持ち越す。
        }
    }

    /// 索引集合の安定ハッシュ。key/title/exists を正規化・整列してから SHA256。
    /// （Swift の Hasher は起動ごとにシード変動して永続比較に使えないため自前で作る）
    private static func fingerprint(of entries: [LinkIndexEntry]) -> String {
        let canonical = entries
            .map { "\($0.exists ? 1 : 0)\t\($0.key)\t\($0.title)\t\($0.path ?? "")" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
