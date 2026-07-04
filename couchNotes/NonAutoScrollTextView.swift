//
//  NonAutoScrollTextView.swift
//  couchNotes
//
//  MarkdownTextView.swift から分割（純粋なコード移動・ロジック変更なし）。
//

import UIKit

// MARK: - 自動スクロールを抑制する UITextView

/// UITextView 標準の「カーソル追従の自動スクロール」（`scrollRectToVisible` 経由）を抑制する。
/// タップ・選択変更で勝手にスクロールしなくなる。手動ドラッグスクロールはそのまま有効。
/// カーソルの可視化が必要になったら、別途 contentOffset を直接操作して行う（Phase 2 以降）。
final class NonAutoScrollTextView: UITextView {
    /// スクロール制御のマスタースイッチ。
    /// true  = 自前制御（自動スクロールを抑制し、revealCaretIfHidden で手動追従）
    /// false = iOS 純正の自動スクロールに委譲（自前追従は無効化）
    /// ※ 純正委譲は暴走／飛びが再発したため true（自前制御）で運用する。
    var suppressesAutoScroll = true

    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        guard !suppressesAutoScroll else { return }
        super.scrollRectToVisible(rect, animated: animated)
    }

    /// 選択／空白トラックパッド時に UITextInteractionAssistant が回す自動スクロール（animated な
    /// setContentOffset）も抑制する。これがないと、scrollRectToVisible だけ止めても autoscroll が
    /// 素通りして下方向へ暴走スクロールしてしまう。カーソルの可視化は revealCaretIfHidden が
    /// contentOffset を直接操作して行うため、ここを止めても支障はない。
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if suppressesAutoScroll && animated { return }
        super.setContentOffset(contentOffset, animated: animated)
    }

    /// キャレットの高さをその位置のフォント行高にクランプする。
    /// 画像行は段落下余白（画像の予約スペース）を持つため、TextKit では段落最終行の
    /// キャレット矩形がその余白分まで縦に伸びてしまう。文字の高さに合わせて詰める（行頭基準は維持）。
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let len = textStorage.length
        guard len > 0 else { return rect }
        let idx = min(max(0, offset(from: beginningOfDocument, to: position)), len - 1)
        if let font = textStorage.attribute(.font, at: idx, effectiveRange: nil) as? UIFont,
           rect.height > font.lineHeight + 1 {
            rect.size.height = font.lineHeight
        }
        return rect
    }

    // MARK: - ハードウェアキーボード・ショートカット

    var onShortcutPaste:      (() -> Void)?   // cmd+V
    var onMenuPaste:          (() -> Void)?   // 編集メニュー「ペースト」
    var onShortcutListToggle: (() -> Void)?   // cmd+Enter
    var onShortcutMoveUp:     (() -> Void)?   // cmd+option+↑
    var onShortcutMoveDown:   (() -> Void)?   // cmd+option+↓
    var onShortcutIndent:     (() -> Void)?   // cmd+option+→
    var onShortcutOutdent:    (() -> Void)?   // cmd+option+←

    override var keyCommands: [UIKeyCommand]? {
        // 単発で押すもの（cmd+V / cmd+Enter）だけ UIKeyCommand で扱う。
        // 押しっぱなしで連続発火しては困る移動・インデント・Tab は pressesBegan 側で扱う。
        [
            UIKeyCommand(input: "v",  modifierFlags: .command, action: #selector(scPaste)),
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(scListToggle)),
        ]
    }

    @objc private func scPaste()      { onShortcutPaste?() }
    @objc private func scListToggle() { onShortcutListToggle?() }

    // 編集メニューの「ペースト」。画像なら Gyazo アップロード、テキストなら通常挿入へ
    // ハンドラ側で振り分ける。未配線なら標準動作にフォールバック。
    override func paste(_ sender: Any?) {
        if let onMenuPaste { onMenuPaste() } else { super.paste(sender) }
    }

    // UITextView 既定の canPerformAction はクリップボードがテキストを持つ時しか
    // paste: を許可しないため、画像だけをコピーした状態だと編集メニューに「ペースト」が
    // 出ない。画像 or テキストがあれば許可して、paste(_:) 経由で画像ペーストに繋ぐ。
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - 押下イベントで扱うショートカット（オートリピート抑止）

    /// 現在押されているショートカットキー。押しっぱなしのリピートを1回だけにするための集合。
    private var activeShortcutKeyCodes: Set<UIKeyboardHIDUsage> = []

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleShortcut($0) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var supered = Set<UIPress>()
        for p in presses {
            if let kc = p.key?.keyCode, activeShortcutKeyCodes.contains(kc) {
                activeShortcutKeyCodes.remove(kc)
            } else {
                supered.insert(p)
            }
        }
        if !supered.isEmpty { super.pressesEnded(supered, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses { if let kc = p.key?.keyCode { activeShortcutKeyCodes.remove(kc) } }
        super.pressesCancelled(presses, with: event)
    }

    /// 該当ショートカットなら実行して true（イベントを消費）。押しっぱなしのリピートは無視する。
    private func handleShortcut(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        let mods = key.modifierFlags.intersection([.command, .alternate, .control, .shift])
        let kc   = key.keyCode
        let cmdOpt: UIKeyModifierFlags = [.command, .alternate]

        var action: (() -> Void)? = nil
        if      kc == .keyboardUpArrow,    mods == cmdOpt { action = onShortcutMoveUp }
        else if kc == .keyboardDownArrow,  mods == cmdOpt { action = onShortcutMoveDown }
        else if kc == .keyboardRightArrow, mods == cmdOpt { action = onShortcutIndent }
        else if kc == .keyboardLeftArrow,  mods == cmdOpt { action = onShortcutOutdent }
        else if kc == .keyboardTab,        mods.isEmpty   { action = onShortcutIndent }   // Tab
        else if kc == .keyboardTab,        mods == .shift { action = onShortcutOutdent }  // Shift+Tab

        guard let action else { return false }
        if activeShortcutKeyCodes.contains(kc) { return true }   // リピートは消費するが実行しない
        activeShortcutKeyCodes.insert(kc)
        action()
        return true
    }

    // MARK: - 本文末尾フッター（バックリンク表示）

    /// 本文の下に差し込むフッター。スクロール領域内に配置するため本文と一緒にスクロールする。
    var footerView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let footerView { addSubview(footerView) }
            setNeedsLayout()
        }
    }
    /// フッターが無い時の下部余白（キーボード用の従来値）
    var defaultBottomInset: CGFloat = 80
    private let footerGap: CGFloat = 24

    override func layoutSubviews() {
        super.layoutSubviews()

        // 画像オーバーレイの再配置はテキスト or 幅が変わった時だけ（スクロール時は子ビューが
        // コンテンツと一緒に動くため再計算不要）。force フラグは画像読み込み後など、幅・本文が
        // 変わらなくても再配置したいときに使う（幅変化と区別して再スタイルの無限ループを防ぐ）。
        let w = bounds.width
        let widthChanged = abs(w - lastImageWidth) > 0.5
        if forceImageRelayout || text != lastImageText || widthChanged {
            forceImageRelayout = false
            lastImageText  = text
            lastImageWidth = w
            EditorImageStore.shared.contentWidth = w - textContainerInset.left - textContainerInset.right
            // 幅が変わると割合指定・均等割り画像の高さが変わるので、段落余白を再計算させる。
            if widthChanged { EditorImageStore.shared.onUpdate?() }
            layoutImagePreviews()
        }

        // フッターは画像配置の後に置く。段落下余白に描かれる画像の底より下へ回すため、
        // 画像フレームが最新になった状態で参照する必要がある。
        positionFooter()
    }

    // MARK: - 画像インラインプレビュー（オーバーレイ）

    private var imagePreviews: [Int: EditorImagePreviewView] = [:]
    private var lastImageText:  String  = "\u{0}"   // 初回必ず実行されるよう番兵
    private var lastImageWidth: CGFloat = -1
    private var forceImageRelayout = false

    /// 画像読み込み完了時などに次回 layout で必ず再配置させる。
    func invalidateImagePreviews() {
        forceImageRelayout = true
        setNeedsLayout()
    }

    /// 画像リンク行の直下（段落余白）に画像ビューを配置する。
    /// 同一行に複数枚あるときは左から横並び（割合指定 or 均等割り）に並べる。
    private func layoutImagePreviews() {
        let groups = MarkdownStyler.imageLineGroups(in: text)

        if groups.isEmpty {
            imagePreviews.values.forEach { $0.removeFromSuperview() }
            imagePreviews.removeAll()
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let contentWidth = bounds.width - textContainerInset.left - textContainerInset.right
        guard contentWidth > 0 else { return }
        EditorImageStore.shared.contentWidth = contentWidth

        let gap = EditorImageStore.imageGap
        var used = Set<Int>()
        var idx  = 0
        for group in groups {
            guard let first = group.first else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: first.lineRange, actualCharacterRange: nil)
            let lineRect   = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let y = textContainerInset.top + lineRect.maxY + 6
            var x = textContainerInset.left

            for im in group {
                let size = EditorImageStore.shared.displaySize(
                    for: im.url, alt: im.alt, contentWidth: contentWidth,
                    countOnLine: group.count, gap: gap)

                let view: EditorImagePreviewView
                if let existing = imagePreviews[idx] {
                    view = existing
                } else {
                    view = EditorImagePreviewView()
                    addSubview(view)
                    imagePreviews[idx] = view
                }
                view.url = im.url
                view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                view.setImage(EditorImageStore.shared.image(for: im.url))
                used.insert(idx)

                EditorImageStore.shared.ensureLoaded(im.url)
                x += size.width + gap
                idx += 1
            }
        }

        for (i, v) in imagePreviews where !used.contains(i) {
            v.removeFromSuperview()
            imagePreviews[i] = nil
        }
    }

    private func positionFooter() {
        guard let footer = footerView else {
            if abs(textContainerInset.bottom - defaultBottomInset) > 0.5 {
                textContainerInset.bottom = defaultBottomInset
            }
            return
        }
        let width = bounds.width - textContainerInset.left - textContainerInset.right
        guard width > 0 else { return }

        let height = footer.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        // 本文の実際の終端位置の下にフッターを置く。ただし画像は段落下余白にオーバーレイ描画され、
        // その分は usedRect に含まれないことがあるので、一番下の画像の底も基準に含めて重なりを防ぐ。
        layoutManager.ensureLayout(for: textContainer)
        let textHeight   = layoutManager.usedRect(for: textContainer).height
        let textBottom   = textContainerInset.top + textHeight
        let imagesBottom = imagePreviews.values.map { $0.frame.maxY }.max() ?? 0
        let y = max(textBottom, imagesBottom) + footerGap
        footer.frame = CGRect(x: textContainerInset.left, y: y, width: width, height: height)

        // フッター（と画像のはみ出し）分の下部余白を確保。差分がある時だけ更新して再レイアウトの
        // 無限ループを防ぐ。画像が本文終端より下へ伸びる場合はその分も余白に反映される。
        let needed = (y + height) - textBottom + defaultBottomInset
        if abs(textContainerInset.bottom - needed) > 0.5 {
            textContainerInset.bottom = needed
        }
    }
}
