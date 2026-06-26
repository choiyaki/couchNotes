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
        positionFooter()

        // 画像オーバーレイの再配置はテキスト or 幅が変わった時だけ（スクロール時は子ビューが
        // コンテンツと一緒に動くため再計算不要）。
        let w = bounds.width
        if text != lastImageText || abs(w - lastImageWidth) > 0.5 {
            lastImageText  = text
            lastImageWidth = w
            layoutImagePreviews()
        }
    }

    // MARK: - 画像インラインプレビュー（オーバーレイ）

    private var imagePreviews: [Int: EditorImagePreviewView] = [:]
    private var lastImageText:  String  = "\u{0}"   // 初回必ず実行されるよう番兵
    private var lastImageWidth: CGFloat = -1

    /// 画像読み込み完了時などに次回 layout で必ず再配置させる。
    func invalidateImagePreviews() {
        lastImageWidth = -1
        setNeedsLayout()
    }

    /// 画像リンク行の直下（段落余白）に画像ビューを配置する。
    private func layoutImagePreviews() {
        guard let regex = MarkdownStyler.imageLinkRegex else { return }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        if matches.isEmpty {
            imagePreviews.values.forEach { $0.removeFromSuperview() }
            imagePreviews.removeAll()
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let contentWidth = bounds.width - textContainerInset.left - textContainerInset.right
        guard contentWidth > 0 else { return }

        var used = Set<Int>()
        for (i, m) in matches.enumerated() where m.numberOfRanges > 1 {
            let urlRange = m.range(at: 1)
            guard urlRange.location != NSNotFound else { continue }
            let url = ns.substring(with: urlRange)

            let lineRange  = ns.lineRange(for: m.range)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect   = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            let size = EditorImageStore.shared.displaySize(for: url, contentWidth: contentWidth)
            let x = textContainerInset.left
            let y = textContainerInset.top + lineRect.maxY + 6

            let view: EditorImagePreviewView
            if let existing = imagePreviews[i] {
                view = existing
            } else {
                view = EditorImagePreviewView()
                addSubview(view)
                imagePreviews[i] = view
            }
            view.url = url
            view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            view.setImage(EditorImageStore.shared.image(for: url))
            used.insert(i)

            EditorImageStore.shared.ensureLoaded(url)
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

        // 本文の実際の終端位置の下にフッターを置く
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let y = textContainerInset.top + textHeight + footerGap
        footer.frame = CGRect(x: textContainerInset.left, y: y, width: width, height: height)

        // フッター分の下部余白を確保（差分がある時だけ更新して再レイアウトの無限ループを防ぐ）
        let needed = footerGap + height + defaultBottomInset
        if abs(textContainerInset.bottom - needed) > 0.5 {
            textContainerInset.bottom = needed
        }
    }
}
