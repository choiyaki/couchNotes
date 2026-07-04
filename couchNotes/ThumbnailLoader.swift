//
//  ThumbnailLoader.swift
//  couchNotes
//
//  ノート一覧カードのサムネイル画像を非同期取得・キャッシュする。
//  SwiftUI の AsyncImage はキャッシュを持たず、セル再利用のたびに再ダウンロード＆
//  途中リクエストをキャンセルするため、スクロール中に画像が表示されないことがある。
//  ここでは URL 単位でダウンロードを共有・キャッシュし、一度読めたら再表示は即時にする。
//

import UIKit

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, UIImage>()
    /// URL ごとの進行中ダウンロード。重複取得を避け、複数カードで結果を共有する。
    private var tasks: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 200   // メモリ過多を避けつつ、可視範囲＋近傍を十分キャッシュ
    }

    /// キャッシュ済みなら即返す（同期）。表示のちらつき回避に使う。
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 画像を取得する。キャッシュがあれば即、無ければダウンロードしてキャッシュする。
    /// 進行中の取得は URL 単位で共有するため、呼び出し側（カード）が
    /// スクロールで破棄されてもダウンロードは継続し、次回表示ではキャッシュから即描画できる。
    func image(for url: URL) async -> UIImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let existing = tasks[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [weak self] in
            let img: UIImage?
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                img = UIImage(data: data)
            } catch {
                img = nil
            }
            if let self, let img { self.cache.setObject(img, forKey: url as NSURL) }
            self?.tasks[url] = nil
            return img
        }
        tasks[url] = task
        return await task.value
    }
}
