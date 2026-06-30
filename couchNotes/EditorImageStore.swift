//
//  EditorImageStore.swift
//  couchNotes
//
//  エディタ内の画像インラインプレビュー用。リモート(https)画像を非同期取得・キャッシュし、
//  向きごとに高さを固定して表示サイズを返す。テキスト本体には一切手を加えず、
//  画像は UIView オーバーレイとして「段落下の余白」に浮かべる（カーソル挙動に影響しない）。
//

import UIKit

// MARK: - 画像ストア（取得・キャッシュ・サイズ計算）

final class EditorImageStore {
    static let shared = EditorImageStore()
    private init() {}

    /// 向きごとの固定高さ（pt）。
    static let portraitHeight:    CGFloat = 240   // 縦向き
    static let landscapeHeight:   CGFloat = 150   // 横向き
    static let placeholderHeight: CGFloat = 200   // 読み込み前の枠

    /// 同一行に複数枚並べるときの画像間ギャップ（pt）。
    static let imageGap: CGFloat = 8

    /// エディタのコンテンツ幅（textContainerInset を除いた本文幅）。
    /// 割合指定・均等割りの算出に使う。レイアウト時にビューが更新する。
    var contentWidth: CGFloat = 0

    private let cache = NSCache<NSURL, UIImage>()
    private var inflight = Set<String>()

    /// 画像が新たに読み込まれたら呼ばれる（メインスレッド）。再スタイル＋再配置のトリガ。
    var onUpdate: (() -> Void)?

    func image(for url: String) -> UIImage? {
        guard let u = URL(string: url) else { return nil }
        return cache.object(forKey: u as NSURL)
    }

    /// 段落下に確保すべき高さ（向き固定）。読み込み前はプレースホルダ高さ。
    func displayHeight(for url: String) -> CGFloat {
        guard let img = image(for: url) else { return Self.placeholderHeight }
        return img.size.width >= img.size.height ? Self.landscapeHeight : Self.portraitHeight
    }

    /// 表示サイズを決める統一ロジック。
    /// - alt の `|NN` 指定があれば コンテンツ幅 × NN%。
    /// - 指定なしで同一行に複数枚あれば 均等割り（ギャップを差し引いて枚数で等分）。
    /// - 指定なしで単独なら 従来の向き固定サイズ。
    func displaySize(for url: String, alt: String,
                     contentWidth: CGFloat, countOnLine: Int, gap: CGFloat) -> CGSize {
        // 幅未確定（レイアウト前）は向き固定にフォールバックして予約高さを確保する。
        guard contentWidth > 0 else {
            return CGSize(width: 0, height: displayHeight(for: url))
        }
        if let frac = MarkdownStyler.widthFraction(fromAlt: alt) {
            return sizeForWidth(contentWidth * frac, url: url)
        }
        if countOnLine > 1 {
            let w = (contentWidth - gap * CGFloat(countOnLine - 1)) / CGFloat(countOnLine)
            return sizeForWidth(max(w, 1), url: url)
        }
        return naturalSize(for: url, contentWidth: contentWidth)
    }

    /// 指定幅での表示サイズ（高さ = 幅 ÷ アスペクト比）。未取得時はプレースホルダ高さ。
    private func sizeForWidth(_ width: CGFloat, url: String) -> CGSize {
        guard let img = image(for: url), img.size.width > 0, img.size.height > 0 else {
            return CGSize(width: width, height: Self.placeholderHeight)
        }
        let aspect = img.size.width / img.size.height
        return CGSize(width: width, height: width / aspect)
    }

    /// 従来の表示サイズ。高さは向き固定、幅はアスペクト比（コンテンツ幅で上限クリップ）。
    private func naturalSize(for url: String, contentWidth: CGFloat) -> CGSize {
        guard let img = image(for: url), img.size.width > 0, img.size.height > 0 else {
            return CGSize(width: min(contentWidth, 160), height: Self.placeholderHeight)
        }
        let aspect  = img.size.width / img.size.height
        let targetH = aspect >= 1 ? Self.landscapeHeight : Self.portraitHeight
        var w = targetH * aspect
        var h = targetH
        if w > contentWidth {        // 極端に横長なら幅で頭打ち
            w = contentWidth
            h = w / aspect
        }
        return CGSize(width: w, height: h)
    }

    /// 未取得なら非同期取得を開始する（取得済み／取得中なら何もしない）。
    func ensureLoaded(_ url: String) {
        guard image(for: url) == nil, !inflight.contains(url), let u = URL(string: url) else { return }
        inflight.insert(url)
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            let img = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(url)
                guard let img else { return }
                self.cache.setObject(img, forKey: u as NSURL)
                self.onUpdate?()
            }
        }.resume()
    }
}

// MARK: - オーバーレイ表示ビュー（タップで Safari）

final class EditorImagePreviewView: UIImageView {
    var url: String?

    init() {
        super.init(frame: .zero)
        configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        contentMode = .scaleAspectFit
        clipsToBounds = true
        layer.cornerRadius = 6
        backgroundColor = .secondarySystemBackground
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    func setImage(_ img: UIImage?) {
        image = img
        backgroundColor = (img == nil) ? .secondarySystemBackground : .clear
    }

    @objc private func handleTap() {
        guard let s = url, let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
