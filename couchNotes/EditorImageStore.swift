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

    /// 実表示サイズ。高さは向き固定、幅はアスペクト比（コンテンツ幅で上限クリップ）。
    func displaySize(for url: String, contentWidth: CGFloat) -> CGSize {
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
