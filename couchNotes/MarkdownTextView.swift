import SwiftUI
import UIKit

// MARK: - Wiki リンク用カスタム属性キー

extension NSAttributedString.Key {
    static let wikiLinkTarget = NSAttributedString.Key("couchNotes.wikiLinkTarget")
    /// 外部リンク（http/https）。値は開く URL 文字列。
    static let externalLinkURL = NSAttributedString.Key("couchNotes.externalLinkURL")
}

// MARK: - 自動スクロールを抑制する UITextView

/// UITextView 標準の「カーソル追従の自動スクロール」（`scrollRectToVisible` 経由）を抑制する。
/// タップ・選択変更で勝手にスクロールしなくなる。手動ドラッグスクロールはそのまま有効。
/// カーソルの可視化が必要になったら、別途 contentOffset を直接操作して行う（Phase 2 以降）。
final class NonAutoScrollTextView: UITextView {
    /// true の間、自動スクロール（scrollRectToVisible）を無視する
    var suppressesAutoScroll = true

    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        guard !suppressesAutoScroll else { return }
        super.scrollRectToVisible(rect, animated: animated)
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

// MARK: - MarkdownTextView

struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var notes: [NoteItem] = []
    var backlinks: [NoteItem] = []
    var fontSize:    CGFloat = MarkdownStyler.defaultFontSize
    var lineSpacing: CGFloat = MarkdownStyler.defaultLineSpacing
    var onLinkTap: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = NonAutoScrollTextView()
        // TextKit 1 互換モードを「生成直後（テキストが空のうち）」に確定させる。
        // タップ時に handleTap が layoutManager にアクセスすると TextKit2→1 切替が起き、
        // その再レイアウトでスクロール位置がトップにリセットされるのを防ぐ。
        _ = tv.layoutManager
        tv.delegate             = context.coordinator
        tv.backgroundColor      = .clear
        tv.isScrollEnabled      = true
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode  = .interactive
        tv.textContainerInset   = UIEdgeInsets(top: 12, left: 12, bottom: 80, right: 12)
        tv.typingAttributes     = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate             = context.coordinator
        tv.addGestureRecognizer(tap)

        context.coordinator.textView = tv

        // 本文末尾のバックリンクフッター（タップでリンク先へナビゲート）
        let footer = BacklinksFooterView()
        let linkTap = onLinkTap
        footer.onTap = { [weak tv] id in
            tv?.resignFirstResponder()
            linkTap?(id)
        }
        context.coordinator.footer = footer

        let coord = context.coordinator
        let accessory = AccessoryContainerView()
        accessory.suggestion.onSelect       = { [weak coord] note in coord?.handleSuggestionTap(note) }
        accessory.toolbar.onPaste           = { [weak coord] in coord?.handlePaste() }
        accessory.toolbar.onDoubleBracket   = { [weak coord] in coord?.handleDoubleBracket() }
        accessory.toolbar.onListToggle      = { [weak coord] in coord?.handleListToggle() }
        accessory.toolbar.onMoveLineUp      = { [weak coord] in coord?.handleMoveLineUp() }
        accessory.toolbar.onMoveLineDown    = { [weak coord] in coord?.handleMoveLineDown() }
        accessory.toolbar.onDecreaseIndent  = { [weak coord] in coord?.handleDecreaseIndent() }
        accessory.toolbar.onIncreaseIndent  = { [weak coord] in coord?.handleIncreaseIndent() }
        coord.accessoryView = accessory
        // inputAccessoryView は一度だけ設定し、以降は入れ替えない（入れ替えは IME を破壊するため）
        tv.inputAccessoryView = accessory

        // Phase 1: キーボードが隠す高さ分だけ下部スクロール余白を確保するための購読
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        return tv
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.notes = notes

        // バックリンクフッターの更新（テキスト変更とは独立に反映する）
        let ids = backlinks.map(\.id)
        if context.coordinator.backlinkIDs != ids,
           let nav = uiView as? NonAutoScrollTextView,
           let footer = context.coordinator.footer {
            context.coordinator.backlinkIDs = ids
            if backlinks.isEmpty {
                nav.footerView = nil
            } else {
                footer.configure(with: backlinks)
                if nav.footerView !== footer { nav.footerView = footer }
                nav.setNeedsLayout()
            }
        }

        let textChanged  = uiView.text != text
        let styleChanged = context.coordinator.fontSize    != fontSize
                        || context.coordinator.lineSpacing != lineSpacing

        if styleChanged {
            context.coordinator.fontSize    = fontSize
            context.coordinator.lineSpacing = lineSpacing
            uiView.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        }

        guard textChanged || styleChanged else { return }

        // 外部更新（ロード／別デバイス反映）でテキストを差し替えても、
        // スクロール位置だけは保つ（カーソル位置・自動スクロールには一切触れない）。
        let savedOffset = uiView.contentOffset
        if textChanged {
            uiView.text = text
        }
        MarkdownStyler.apply(to: uiView.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
        uiView.contentOffset = savedOffset
    }
}

// MARK: - Coordinator

extension MarkdownTextView {
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let parent: MarkdownTextView
        private var isStyling = false
        weak var textView: UITextView?

        var notes: [NoteItem] = []
        var fontSize:    CGFloat = MarkdownStyler.defaultFontSize
        var lineSpacing: CGFloat = MarkdownStyler.defaultLineSpacing
        var accessoryView: AccessoryContainerView?
        var footer: BacklinksFooterView?
        var backlinkIDs: [String] = []

        init(_ parent: MarkdownTextView) { self.parent = parent }

        // MARK: サジェスト制御

        func updateSuggestions(for tv: UITextView) {
            guard tv.isFirstResponder else { return }

            // IME 変換中はマークテキスト末尾をカーソル位置とする
            let pos: Int
            if let marked = tv.markedTextRange {
                pos = tv.offset(from: tv.beginningOfDocument, to: marked.end)
            } else {
                pos = tv.selectedRange.location
            }
            guard pos > 0 else { clearSuggestions(for: tv); return }

            let prefix = (tv.text as NSString).substring(to: pos)
            guard let query = wikiLinkQuery(in: prefix), !query.isEmpty else {
                clearSuggestions(for: tv)
                return
            }

            let lower = query.lowercased()
            let hits  = notes
                .filter { $0.shortTitle.lowercased().contains(lower) }
                .prefix(10)

            guard !hits.isEmpty else { clearSuggestions(for: tv); return }

            // コンテナ内でサジェストを更新・表示（inputAccessoryView は入れ替えない）
            accessoryView?.suggestion.update(with: Array(hits))
            accessoryView?.showSuggestion()
        }

        private func clearSuggestions(for tv: UITextView) {
            accessoryView?.showToolbar()
        }

        // MARK: ツールバーアクション

        func handlePaste() {
            guard let tv = textView else { return }
            guard let pasteText = UIPasteboard.general.string, !pasteText.isEmpty else { return }
            tv.insertText(pasteText)   // textViewDidChange 経由でスタイリングと parent.text 反映
        }

        /// `[[]]` を挿入する。選択範囲があれば囲む。
        func handleDoubleBracket() {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            let ns    = tv.text as NSString
            let selected = ns.substring(with: range)
            let inserted = "[[\(selected)]]"

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: range, with: inserted)
            tv.textStorage.endEditing()

            // カーソル: 選択なしなら `[[|]]`、選択ありなら `[[selected]]|`
            let newLoc = range.length == 0
                ? range.location + 2
                : range.location + (inserted as NSString).length
            tv.selectedRange = NSRange(location: newLoc, length: 0)

            applyStylingAfterEdit(tv)
        }

        /// リスト → チェックボックス → 完了 → リスト の 3 状態トグル。
        /// プレーン行の場合は `- ` を付与してサイクルに入る。
        func handleListToggle() {
            guard let tv = textView else { return }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            var line      = ns.substring(with: lineRange)
            let hasNewline = line.hasSuffix("\n")
            if hasNewline { line = String(line.dropLast()) }

            let tabs     = String(line.prefix(while: { $0 == "\t" }))
            let stripped = String(line.dropFirst(tabs.count))

            let oldMarkerLen: Int
            let newMarker:    String

            if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("* [ ]") {
                let m = String(stripped.prefix(1))
                newMarker    = "\(m) [x] "
                oldMarkerLen = 6
            } else if stripped.hasPrefix("- [x]") || stripped.hasPrefix("* [x]") {
                let m = String(stripped.prefix(1))
                newMarker    = "\(m) "
                oldMarkerLen = 6
            } else if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") {
                let m = String(stripped.prefix(1))
                newMarker    = "\(m) [ ] "
                oldMarkerLen = 2
            } else if stripped.hasPrefix("+ ") {
                newMarker    = "- [ ] "
                oldMarkerLen = 2
            } else {
                newMarker    = "- "
                oldMarkerLen = 0
            }

            let body = String(stripped.dropFirst(oldMarkerLen))
            let newLine = tabs + newMarker + body + (hasNewline ? "\n" : "")

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: lineRange, with: newLine)
            tv.textStorage.endEditing()

            // カーソル位置調整: マーカー上にいたら新マーカー末尾、本文中ならデルタ分シフト
            let tabBytes        = (tabs as NSString).length
            let oldMarkerEnd    = lineRange.location + tabBytes + oldMarkerLen
            let newMarkerBytes  = (newMarker as NSString).length
            let newMarkerEnd    = lineRange.location + tabBytes + newMarkerBytes
            let newCursor: Int
            if cursorLoc < oldMarkerEnd {
                newCursor = newMarkerEnd
            } else {
                newCursor = cursorLoc + (newMarkerBytes - oldMarkerLen)
            }
            tv.selectedRange = NSRange(location: clamp(newCursor, in: tv), length: 0)

            applyStylingAfterEdit(tv)
        }

        func handleMoveLineUp() {
            guard let tv = textView else { return }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let currRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            guard currRange.location > 0 else { return }
            let prevRange = ns.lineRange(for: NSRange(location: currRange.location - 1, length: 0))

            let prevText = ns.substring(with: prevRange)
            let currText = ns.substring(with: currRange)
            // 行内容（末尾改行を除く）を取り出して入れ替え、改行構造を保存
            let prevBody = prevText.hasSuffix("\n") ? String(prevText.dropLast()) : prevText
            let currHasNL = currText.hasSuffix("\n")
            let currBody = currHasNL ? String(currText.dropLast()) : currText

            let newContent = currBody + "\n" + prevBody + (currHasNL ? "\n" : "")
            let combined = NSRange(location: prevRange.location,
                                   length: prevRange.length + currRange.length)
            let cursorInCurr = cursorLoc - currRange.location

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: combined, with: newContent)
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: clamp(prevRange.location + cursorInCurr, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        func handleMoveLineDown() {
            guard let tv = textView else { return }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let currRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let nextStart = currRange.location + currRange.length
            guard nextStart < ns.length else { return }
            let nextRange = ns.lineRange(for: NSRange(location: nextStart, length: 0))

            let currText = ns.substring(with: currRange)  // 必ず \n で終わる（次行があるため）
            let nextText = ns.substring(with: nextRange)
            let currBody = String(currText.dropLast())
            let nextHasNL = nextText.hasSuffix("\n")
            let nextBody = nextHasNL ? String(nextText.dropLast()) : nextText

            let newContent = nextBody + "\n" + currBody + (nextHasNL ? "\n" : "")
            let combined = NSRange(location: currRange.location,
                                   length: currRange.length + nextRange.length)
            let cursorInCurr = cursorLoc - currRange.location

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: combined, with: newContent)
            tv.textStorage.endEditing()

            // curr は nextBody の後ろに移る
            let newCurrStart = currRange.location + (nextBody as NSString).length + 1
            tv.selectedRange = NSRange(location: clamp(newCurrStart + cursorInCurr, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        func handleDecreaseIndent() {
            guard let tv = textView else { return }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let line      = ns.substring(with: lineRange)
            guard line.hasPrefix("\t") else { return }

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: "")
            tv.textStorage.endEditing()

            let newCursor = max(lineRange.location, cursorLoc - 1)
            tv.selectedRange = NSRange(location: clamp(newCursor, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        func handleIncreaseIndent() {
            guard let tv = textView else { return }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: "\t")
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: clamp(cursorLoc + 1, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        // MARK: ツールバーアクション共通ユーティリティ

        private func applyStylingAfterEdit(_ tv: UITextView) {
            MarkdownStyler.apply(to: tv.textStorage, notes: notes,
                                 fontSize: fontSize, lineSpacing: lineSpacing)
            parent.text = tv.text
            tv.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        }

        private func clamp(_ loc: Int, in tv: UITextView) -> Int {
            max(0, min(loc, tv.text.utf16.count))
        }

        /// カーソル直前テキストから [[ 以降の検索クエリを返す。[[ がなければ nil
        private func wikiLinkQuery(in prefix: String) -> String? {
            guard let openRange = prefix.range(of: "[[", options: .backwards) else { return nil }
            let after = String(prefix[openRange.upperBound...])
            guard !after.contains("]]"), !after.contains("\n") else { return nil }
            return after
        }

        func handleSuggestionTap(_ note: NoteItem) {
            guard let tv = textView else { return }
            let pos    = tv.selectedRange.location
            let prefix = (tv.text as NSString).substring(to: pos)
            guard let query = wikiLinkQuery(in: prefix) else { return }

            // [[query → [[shortTitle]] に置換
            let replaceLen   = 2 + (query as NSString).length
            let replaceStart = pos - replaceLen
            guard replaceStart >= 0 else { return }

            // カーソル直後に既存の "]]"（ツールバーの [[]] 挿入由来）があれば一緒に置換し、
            // 置換文字列側の "]]" と重複して "]]]]" になるのを防ぐ
            let ns = tv.text as NSString
            var tailLen = 0
            if pos + 2 <= ns.length,
               ns.substring(with: NSRange(location: pos, length: 2)) == "]]" {
                tailLen = 2
            }

            let replacement = "[[\(note.shortTitle)]]"
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(
                in: NSRange(location: replaceStart, length: replaceLen + tailLen),
                with: replacement
            )
            tv.textStorage.endEditing()
            tv.selectedRange = NSRange(location: replaceStart + (replacement as NSString).length, length: 0)

            MarkdownStyler.apply(to: tv.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            parent.text = tv.text
            clearSuggestions(for: tv)
        }

        // MARK: キーボード（Phase 1: 余白確保 / Phase 2: フォーカス時のカーソル可視化）

        /// キーボードが隠している高さ分だけ contentInset.bottom を確保する（Phase 1）。
        /// 高さは通知の矩形（keyboardFrameEnd）から算出するので、機種・向き・
        /// inputAccessoryView・日本語IMEの候補バー等の差をそのまま反映できる。
        /// その後、カーソルが隠れていれば最小限スクロールして見せる（Phase 2）。
        @objc func keyboardWillShow(_ notification: Notification) {
            guard
                let tv      = textView, tv.isFirstResponder,
                let kbFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                let window  = tv.window
            else { return }

            let tvMaxY  = tv.convert(CGPoint(x: 0, y: tv.bounds.maxY), to: window).y
            let overlap = max(0, tvMaxY - kbFrame.minY)

            tv.contentInset.bottom = overlap
            tv.verticalScrollIndicatorInsets.bottom = overlap

            revealCaretIfHidden(in: tv)
        }

        @objc func keyboardWillHide(_ notification: Notification) {
            guard let tv = textView else { return }
            tv.contentInset.bottom = 0
            tv.verticalScrollIndicatorInsets.bottom = 0
        }

        /// カーソルがキーボードに隠れている時だけ、隠れている分＋余白だけ下方向に
        /// スクロールして見せる（Phase 2）。見えている場合や上方向には動かさない。
        /// scrollRectToVisible は使わず contentOffset を直接設定するため、Phase 1 の
        /// 自動スクロール抑制と両立する。
        private func revealCaretIfHidden(in tv: UITextView) {
            guard let range = tv.selectedTextRange else { return }
            let caret = tv.caretRect(for: range.end)
            guard caret.maxY.isFinite else { return }

            let padding: CGFloat = 60   // キーボード上端からの余白（調整可）
            let visibleHeight = tv.bounds.height - tv.contentInset.bottom
            let visibleBottom = tv.contentOffset.y + visibleHeight

            // カーソル下端が見える範囲の下端より下＝隠れている時だけ
            guard caret.maxY + padding > visibleBottom else { return }

            let maxOffsetY = max(0, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
            let targetY = min(caret.maxY + padding - visibleHeight, maxOffsetY)
            // 下方向のみ反映（上には動かさない）
            if targetY > tv.contentOffset.y {
                tv.contentOffset.y = targetY
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            updateSuggestions(for: textView)
        }

        // MARK: リスト自動補完

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }

            let ns        = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var line      = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line = String(line.dropLast()) }
            if line.hasSuffix("\r") { line = String(line.dropLast()) }

            let tabs     = String(line.prefix(while: { $0 == "\t" }))
            let stripped = String(line.dropFirst(tabs.count))

            // リストマーカーを判定し、次行に引き継ぐマーカーを決定する
            let nextMarker: String
            let afterMarker: Substring

            if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("* [ ]") {
                nextMarker  = String(stripped.prefix(1)) + " [ ] "
                afterMarker = stripped.dropFirst(5).drop(while: { $0 == " " })
            } else if stripped.hasPrefix("- [x]") || stripped.hasPrefix("* [x]") {
                // 完了済みは次行を未チェックで開始
                nextMarker  = String(stripped.prefix(1)) + " [ ] "
                afterMarker = stripped.dropFirst(5).drop(while: { $0 == " " })
            } else if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                nextMarker  = String(stripped.prefix(2))
                afterMarker = stripped.dropFirst(2)
            } else {
                return true
            }

            if afterMarker.isEmpty {
                // 空のリスト項目 → 行全体のマーカーを除去してリストを終了
                let lineContentRange = NSRange(location: lineRange.location,
                                               length: (line as NSString).length)
                textView.textStorage.beginEditing()
                textView.textStorage.replaceCharacters(in: lineContentRange, with: "")
                textView.textStorage.endEditing()
                textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            } else {
                // リスト継続: 改行 + タブ + マーカーを挿入
                let insert = "\n\(tabs)\(nextMarker)" as NSString
                textView.textStorage.beginEditing()
                textView.textStorage.replaceCharacters(in: range, with: insert as String)
                textView.textStorage.endEditing()
                textView.selectedRange = NSRange(location: range.location + insert.length, length: 0)
            }

            MarkdownStyler.apply(to: textView.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            parent.text = textView.text
            updateSuggestions(for: textView)
            revealCaretIfHidden(in: textView)   // Phase 4: リスト行の改行でカーソルが隠れたら見せる
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isStyling else { return }

            isStyling = true
            MarkdownStyler.apply(to: textView.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            isStyling = false

            parent.text = textView.text
            textView.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            updateSuggestions(for: textView)
            revealCaretIfHidden(in: textView)   // Phase 4: 入力・改行でカーソルが隠れたら見せる
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isStyling else { return }
            updateSuggestions(for: textView)
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: タップ処理（Wiki リンク・チェックボックス）

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = gesture.view as? UITextView else { return }

            // gesture.location(in:) はコンテンツ座標系を返すが、layoutManager は
            // テキストコンテナ座標系を期待するため textContainerInset 分だけ補正する
            let rawPt = gesture.location(in: tv)
            let pt    = CGPoint(
                x: rawPt.x - tv.textContainerInset.left,
                y: rawPt.y - tv.textContainerInset.top
            )

            let ns = tv.text as NSString
            guard ns.length > 0 else { return }

            // closestPosition / characterIndex は常に最近傍の文字へスナップするため、
            // 行末リンクの後方や最終行の下の空白をタップしてもリンク扱いになってしまう。
            // グリフの実際の境界内をタップしているか確認することでタップエリアを限定する。
            let lm        = tv.layoutManager
            let container = tv.textContainer
            let glyphIdx  = lm.glyphIndex(for: pt, in: container, fractionOfDistanceThroughGlyph: nil)
            let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: container)
            let onGlyph   = glyphRect.contains(pt)

            let idx = lm.characterIndexForGlyph(at: glyphIdx)
            guard idx < ns.length else { return }

            // --- Wiki リンク判定（グリフ上を実際にタップした場合のみ）---
            if onGlyph,
               let target = tv.textStorage.attribute(.wikiLinkTarget, at: idx, effectiveRange: nil) as? String {
                tv.resignFirstResponder()          // キーボードを閉じてからナビゲート
                parent.onLinkTap?(target)
                return
            }

            // --- 外部リンク判定（グリフ上を実際にタップした場合のみ）→ Safari で開く ---
            if onGlyph,
               let urlStr = tv.textStorage.attribute(.externalLinkURL, at: idx, effectiveRange: nil) as? String,
               let url = URL(string: urlStr) {
                tv.resignFirstResponder()
                UIApplication.shared.open(url)
                return
            }

            // --- チェックボックス判定（グリフ上・先頭6文字以内のみ）---
            guard onGlyph else { return }
            let lineRange    = ns.lineRange(for: NSRange(location: idx, length: 0))
            let line         = ns.substring(with: lineRange)
            let offsetInLine = idx - lineRange.location
            guard offsetInLine < 6 else { return }

            let replacement: String
            if      line.hasPrefix("- [ ]") || line.hasPrefix("* [ ]") { replacement = "[x]" }
            else if line.hasPrefix("- [x]") || line.hasPrefix("* [x]") { replacement = "[ ]" }
            else    { return }

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(
                in: NSRange(location: lineRange.location + 2, length: 3),
                with: replacement
            )
            tv.textStorage.endEditing()
            MarkdownStyler.apply(to: tv.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            parent.text = tv.text
        }
    }
}

// MARK: - MarkdownStyler

enum MarkdownStyler {
    static let defaultFontSize:    CGFloat = 16
    static let defaultLineSpacing: CGFloat = 0

    private static let wikiLinkRegex = try? NSRegularExpression(pattern: #"\[\[[^\]]+\]\]"#)
    private static let blockIDRegex  = try? NSRegularExpression(
        pattern: #"\^[a-zA-Z0-9_-]+$"#,
        options: .anchorsMatchLines
    )

    static func baseAttributes(fontSize: CGFloat = defaultFontSize,
                               lineSpacing: CGFloat = defaultLineSpacing) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label,
        ]
        if lineSpacing > 0 {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = lineSpacing
            attrs[.paragraphStyle] = para
        }
        return attrs
    }

    static func apply(to storage: NSTextStorage,
                      notes: [NoteItem] = [],
                      fontSize: CGFloat = defaultFontSize,
                      lineSpacing: CGFloat = defaultLineSpacing) {
        let len = storage.length
        guard len > 0 else { return }
        let full = NSRange(location: 0, length: len)

        let baseFont    = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let blockIDFont = UIFont.monospacedSystemFont(ofSize: max(fontSize * 0.69, 10), weight: .regular)

        storage.addAttribute(.font,            value: baseFont,      range: full)
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.removeAttribute(.paragraphStyle,     range: full)
        storage.removeAttribute(.wikiLinkTarget,     range: full)
        storage.removeAttribute(.externalLinkURL,    range: full)
        storage.removeAttribute(.underlineStyle,     range: full)

        // 行間を全体に適用（リスト行は後でぶら下げと合成して上書き）
        if lineSpacing > 0 {
            let basePara = NSMutableParagraphStyle()
            basePara.lineSpacing = lineSpacing
            storage.addAttribute(.paragraphStyle, value: basePara, range: full)
        }

        (storage.string as NSString).enumerateSubstrings(in: full, options: .byLines) { sub, lineRange, _, _ in
            guard let line = sub else { return }
            styleLine(line, at: lineRange, in: storage, baseFont: baseFont, lineSpacing: lineSpacing)
        }

        styleWikiLinks(in: storage, range: full, notes: notes)
        styleExternalLinks(in: storage, range: full)
        styleBlockIDs(in: storage, range: full, font: blockIDFont)
    }

    private static func styleLine(_ line: String, at range: NSRange, in s: NSTextStorage,
                                  baseFont: UIFont, lineSpacing: CGFloat) {
        let fontSize = baseFont.pointSize
        // 見出し（タブ前置なし想定）
        if line.hasPrefix("### ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.1875, weight: .semibold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(4, range.length)))
            return
        }
        if line.hasPrefix("## ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.375, weight: .bold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(3, range.length)))
            return
        }
        if line.hasPrefix("# ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.625, weight: .bold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(2, range.length)))
            return
        }

        // リスト項目（タブによるネストに対応）
        let tabCount    = line.prefix(while: { $0 == "\t" }).count
        let stripped    = String(line.dropFirst(tabCount))
        let markerLoc   = range.location + tabCount
        let markerAvail = max(0, range.length - tabCount)

        let prefixForMeasure: String

        if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("* [ ]") {
            s.addAttribute(.foregroundColor,
                           value: UIColor.systemBlue.withAlphaComponent(0.8),
                           range: NSRange(location: markerLoc, length: min(5, markerAvail)))
            prefixForMeasure = "- [ ] "

        } else if stripped.hasPrefix("- [x]") || stripped.hasPrefix("* [x]") {
            s.addAttribute(.foregroundColor, value: UIColor.systemGreen,
                           range: NSRange(location: markerLoc, length: min(5, markerAvail)))
            if markerAvail > 6 {
                let bodyRange = NSRange(location: markerLoc + 6, length: markerAvail - 6)
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: bodyRange)
                s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: bodyRange)
            }
            prefixForMeasure = "- [x] "

        } else if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: markerLoc, length: min(2, markerAvail)))
            prefixForMeasure = String(stripped.prefix(2))

        } else {
            return
        }

        // ぶら下げインデント（フォントサイズ比例のタブ幅 + 実際のプレフィックス幅）
        let tabWidth    = fontSize * 1.75
        let prefixWidth = (prefixForMeasure as NSString)
            .size(withAttributes: [.font: baseFont]).width
        let para = NSMutableParagraphStyle()
        para.headIndent  = CGFloat(tabCount) * tabWidth + prefixWidth
        para.lineSpacing = lineSpacing
        s.addAttribute(.paragraphStyle, value: para, range: range)
    }

    private static func styleWikiLinks(in s: NSTextStorage, range: NSRange, notes: [NoteItem]) {
        guard let regex = wikiLinkRegex else { return }
        for m in regex.matches(in: s.string, range: range) {
            guard m.range.length > 4 else { continue }
            let innerRange = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            let linkText   = (s.string as NSString).substring(with: innerRange)
            let lower      = linkText.lowercased()
            let exists     = notes.contains { $0.shortTitle.lowercased() == lower }
            s.addAttribute(.foregroundColor,
                           value: exists ? UIColor.systemBlue : UIColor.systemBlue.withAlphaComponent(0.35),
                           range: m.range)
            s.addAttribute(.wikiLinkTarget, value: linkText + ".md", range: m.range)
        }
    }

    // 画像でない Markdown リンク `[text](http…)`（先頭の ! を除外）。capture 1 = URL。
    private static let mdLinkRegex = try? NSRegularExpression(
        pattern: #"(?<!\!)\[[^\]]*\]\((https?://[^)\s]+)\)"#
    )
    // 裸の URL（http/https）。
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s)\]]+"#
    )

    /// 外部リンク（Markdown リンク／裸 URL）に色・下線とタップ用 URL 属性を付ける。
    private static func styleExternalLinks(in s: NSTextStorage, range: NSRange) {
        let ns = s.string as NSString

        func mark(_ matchRange: NSRange, url: String) {
            s.addAttribute(.externalLinkURL, value: url, range: matchRange)
            s.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: matchRange)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: matchRange)
        }

        // 1) Markdown リンク（`![]()` 画像は除外）
        if let regex = mdLinkRegex {
            for m in regex.matches(in: s.string, range: range) where m.numberOfRanges > 1 {
                let urlRange = m.range(at: 1)
                guard urlRange.location != NSNotFound else { continue }
                mark(m.range, url: ns.substring(with: urlRange))
            }
        }

        // 2) 裸 URL（既にリンク属性が付いている範囲＝Markdown リンク内は除外）
        if let regex = bareURLRegex {
            for m in regex.matches(in: s.string, range: range) {
                if s.attribute(.externalLinkURL, at: m.range.location, effectiveRange: nil) != nil { continue }
                mark(m.range, url: ns.substring(with: m.range))
            }
        }
    }

    private static func styleBlockIDs(in s: NSTextStorage, range: NSRange, font: UIFont) {
        guard let regex = blockIDRegex else { return }
        for m in regex.matches(in: s.string, range: range) {
            s.addAttribute(.font,            value: font,                   range: m.range)
            s.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: m.range)
        }
    }
}

// MARK: - SuggestionAccessoryView

final class SuggestionAccessoryView: UIView {
    var onSelect: ((NoteItem) -> Void)?

    private let scrollView = UIScrollView()

    // ボタンの高さと縦方向の余白
    private static let btnH: CGFloat = 30
    private static let vPad: CGFloat = (44 - btnH) / 2

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator   = false
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(with notes: [NoteItem]) {
        scrollView.subviews.forEach { $0.removeFromSuperview() }

        var x: CGFloat = 12

        for note in notes {
            var cfg = UIButton.Configuration.filled()
            cfg.title               = note.shortTitle
            cfg.baseForegroundColor = .label
            cfg.baseBackgroundColor = .tertiarySystemFill
            cfg.cornerStyle         = .medium
            cfg.buttonSize          = .small

            let btn = UIButton(configuration: cfg)
            // intrinsicContentSize でタイトル幅を取得してフレームを手動計算
            let w = max(btn.intrinsicContentSize.width, 44)
            btn.frame = CGRect(x: x, y: Self.vPad, width: w, height: Self.btnH)
            btn.addAction(UIAction { [weak self] _ in self?.onSelect?(note) },
                          for: .touchUpInside)
            scrollView.addSubview(btn)
            x += w + 8
        }

        // contentSize を明示的に設定して横スクロールを確実に有効化
        scrollView.contentSize = CGSize(width: x + 8, height: 44)
        scrollView.setContentOffset(.zero, animated: false)
    }
}

// MARK: - KeyboardToolbarView

/// ソフトウェアキーボード上部の常駐ツールバー。
/// 後でボタンを追加しやすいように、内部で UIStackView を使った横スクロール構造にしている。
final class KeyboardToolbarView: UIView {
    var onPaste:           (() -> Void)?
    var onDoubleBracket:   (() -> Void)?
    var onListToggle:      (() -> Void)?
    var onMoveLineUp:      (() -> Void)?
    var onMoveLineDown:    (() -> Void)?
    var onDecreaseIndent:  (() -> Void)?
    var onIncreaseIndent:  (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack      = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator   = false
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        stack.axis      = .horizontal
        stack.spacing   = 4
        stack.alignment = .center
        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // ボタン追加（左から: ペースト・[[]]・リストトグル・行↑・行↓・インデント-・インデント+）
        stack.addArrangedSubview(makeButton(systemImage: "doc.on.clipboard") { [weak self] in self?.onPaste?() })
        stack.addArrangedSubview(makeButton(title: "[[ ]]")                  { [weak self] in self?.onDoubleBracket?() })
        stack.addArrangedSubview(makeButton(systemImage: "checklist")        { [weak self] in self?.onListToggle?() })
        stack.addArrangedSubview(makeButton(systemImage: "chevron.up")       { [weak self] in self?.onMoveLineUp?() })
        stack.addArrangedSubview(makeButton(systemImage: "chevron.down")     { [weak self] in self?.onMoveLineDown?() })
        stack.addArrangedSubview(makeButton(systemImage: "decrease.indent")  { [weak self] in self?.onDecreaseIndent?() })
        stack.addArrangedSubview(makeButton(systemImage: "increase.indent")  { [weak self] in self?.onIncreaseIndent?() })
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(title: String? = nil,
                            systemImage: String? = nil,
                            action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        if let title       { cfg.title = title }
        if let systemImage { cfg.image = UIImage(systemName: systemImage) }
        cfg.imagePadding = 4
        cfg.buttonSize   = .small
        cfg.baseForegroundColor = .label

        let btn = UIButton(configuration: cfg)
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }
}

// MARK: - AccessoryContainerView

/// inputAccessoryView として一度だけ attach されるコンテナ。
/// 内部にツールバーとサジェストを両方持ち、isHidden の切り替えだけで表示モードを変更する。
/// inputAccessoryView 自体を入れ替えないため、IME の変換状態が維持される。
final class AccessoryContainerView: UIInputView {
    let toolbar    = KeyboardToolbarView()
    let suggestion = SuggestionAccessoryView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44),
                   inputViewStyle: .keyboard)
        for v in [toolbar as UIView, suggestion as UIView] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        suggestion.isHidden = true  // 初期状態はツールバー
    }
    required init?(coder: NSCoder) { fatalError() }

    func showToolbar() {
        toolbar.isHidden    = false
        suggestion.isHidden = true
    }

    func showSuggestion() {
        toolbar.isHidden    = true
        suggestion.isHidden = false
    }
}

// MARK: - BacklinksFooterView

/// 本文末尾に表示するバックリンク（リンク元）一覧。UITextView のスクロール領域に差し込む。
final class BacklinksFooterView: UIView {
    var onTap: ((String) -> Void)?

    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        stack.axis    = .vertical
        stack.spacing = 4
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with backlinks: [NoteItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(10, after: separator)

        let header = UILabel()
        header.text      = "リンク元 (\(backlinks.count))"
        header.font      = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabel
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)

        for note in backlinks {
            stack.addArrangedSubview(makeRow(note))
        }
    }

    private func makeRow(_ note: NoteItem) -> UIView {
        let control = UIControl()
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 2
        inner.isUserInteractionEnabled = false
        control.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: control.topAnchor, constant: 6),
            inner.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -6),
            inner.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: control.trailingAnchor),
        ])

        let title = UILabel()
        title.text          = note.shortTitle
        title.font          = .systemFont(ofSize: 15, weight: .medium)
        title.textColor     = .systemBlue
        title.numberOfLines = 1
        inner.addArrangedSubview(title)

        if let preview = note.preview, !preview.isEmpty {
            let body = UILabel()
            body.text          = preview
            body.font          = .systemFont(ofSize: 12)
            body.textColor     = .secondaryLabel
            body.numberOfLines = 2
            inner.addArrangedSubview(body)
        }

        control.addAction(UIAction { [weak self] _ in self?.onTap?(note.id) }, for: .touchUpInside)
        return control
    }
}
