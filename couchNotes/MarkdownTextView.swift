import SwiftUI
import UIKit
import PhotosUI

// MARK: - Wiki リンク用カスタム属性キー

extension NSAttributedString.Key {
    static let wikiLinkTarget = NSAttributedString.Key("couchNotes.wikiLinkTarget")
    /// 外部リンク（http/https）。値は開く URL 文字列。
    static let externalLinkURL = NSAttributedString.Key("couchNotes.externalLinkURL")
}


// MARK: - MarkdownTextView

struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var notes: [NoteItem] = []
    var backlinks: [NoteItem] = []
    var fontSize:    CGFloat = MarkdownStyler.defaultFontSize
    var lineSpacing: CGFloat = MarkdownStyler.defaultLineSpacing
    var horizontalInset: CGFloat = 0   // テキストの左右内側余白（ランドスケープ時の余白用。ビューは全幅のまま）
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
        tv.textContainerInset   = UIEdgeInsets(top: 12, left: 12 + horizontalInset, bottom: 80, right: 12 + horizontalInset)
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
        // キーボード上の浮動候補リスト
        let panel = SuggestionPanelView()
        panel.isHidden = true
        panel.onSelect = { [weak coord] note in coord?.handleSuggestionTap(note) }
        coord.suggestionPanel = panel

        let accessory = AccessoryContainerView()
        accessory.toolbar.onPaste           = { [weak coord] in coord?.handlePaste() }
        accessory.toolbar.onUploadImage     = { [weak coord] in coord?.handleUploadImage() }
        accessory.toolbar.onDoubleBracket   = { [weak coord] in coord?.handleDoubleBracket() }
        accessory.toolbar.onListToggle      = { [weak coord] in coord?.handleListToggle() }
        accessory.toolbar.onMoveLineUp      = { [weak coord] in coord?.handleMoveLineUp() }
        accessory.toolbar.onMoveLineDown    = { [weak coord] in coord?.handleMoveLineDown() }
        accessory.toolbar.onDecreaseIndent  = { [weak coord] in coord?.handleDecreaseIndent() }
        accessory.toolbar.onIncreaseIndent  = { [weak coord] in coord?.handleIncreaseIndent() }
        coord.accessoryView = accessory
        // inputAccessoryView は一度だけ設定し、以降は入れ替えない（入れ替えは IME を破壊するため）
        tv.inputAccessoryView = accessory

        // ハードウェアキーボードのショートカット（カスタムキーボードの各操作に対応）
        tv.onShortcutPaste      = { [weak coord] in coord?.handlePaste() }
        tv.onMenuPaste          = { [weak coord] in coord?.handlePaste() }
        tv.onShortcutListToggle = { [weak coord] in coord?.handleListToggle() }
        tv.onShortcutMoveUp     = { [weak coord] in coord?.handleMoveLineUp() }
        tv.onShortcutMoveDown   = { [weak coord] in coord?.handleMoveLineDown() }
        tv.onShortcutIndent     = { [weak coord] in coord?.handleIncreaseIndent() }
        tv.onShortcutOutdent    = { [weak coord] in coord?.handleDecreaseIndent() }

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

        // 画像読み込み完了 → 余白(段落)の再スタイル＋オーバーレイ再配置
        EditorImageStore.shared.onUpdate = { [weak coord] in coord?.reapplyStylingForImageLoad() }

        return tv
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        EditorImageStore.shared.onUpdate = nil
        coordinator.suggestionPanel?.removeFromSuperview()
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.notes = notes

        // ランドスケープ余白：テキストの左右内側インセットを向きの変化に追従させる（ビュー幅は変えない）。
        let targetLR = 12 + horizontalInset
        if abs(uiView.textContainerInset.left - targetLR) > 0.5 {
            uiView.textContainerInset.left  = targetLR
            uiView.textContainerInset.right = targetLR
            uiView.setNeedsLayout()
        }

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
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, PHPickerViewControllerDelegate {
        let parent: MarkdownTextView
        private var isStyling = false
        /// 直近のユーザー編集範囲（打鍵時に変更段落だけ再スタイルするため）。programmatic 編集では nil。
        private var pendingChangeRange: NSRange?
        weak var textView: UITextView?

        var notes: [NoteItem] = []
        var fontSize:    CGFloat = MarkdownStyler.defaultFontSize
        var lineSpacing: CGFloat = MarkdownStyler.defaultLineSpacing
        var accessoryView: AccessoryContainerView?
        var suggestionPanel: SuggestionPanelView?       // キーボード上の浮動候補リスト
        private var keyboardTopY: CGFloat = 0           // キーボード（＝アクセサリ）上端の window 座標 Y
        private var keyboardOverlap: CGFloat = 0        // キーボードが本文に被っている高さ
        var footer: BacklinksFooterView?
        var backlinkIDs: [String] = []
        /// 画像ピッカー表示でフォーカスが外れる前に控えたカーソル位置
        private var savedImageInsertLocation: Int = 0

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
                .prefix(15)   // 取得は最大15件（画面表示は4件、残りは内部スクロール）

            guard !hits.isEmpty else { clearSuggestions(for: tv); return }

            showSuggestionPanel(Array(hits))
        }

        private func clearSuggestions(for tv: UITextView) {
            hideSuggestionPanel()
        }

        // MARK: 候補パネル（キーボード上の浮動リスト）

        private func showSuggestionPanel(_ items: [NoteItem]) {
            guard let tv = textView, let window = tv.window, let panel = suggestionPanel else { return }
            if panel.superview !== window { window.addSubview(panel) }
            window.bringSubviewToFront(panel)
            panel.update(with: items)
            panel.isHidden = false
            accessoryView?.setSuggesting(true)   // 候補中はツールバー自体を畳む
            positionSuggestionPanel(in: window)
            applyBottomInset()                   // 下インセットに候補パネル分を足す
            revealCaretIfHidden(in: tv)          // カーソル行をパネルの真上まで持ち上げる
        }

        private func hideSuggestionPanel() {
            suggestionPanel?.isHidden = true
            accessoryView?.setSuggesting(false)
            applyBottomInset()
        }

        /// キーボード（アクセサリ）上端に密着させて配置する。
        private func positionSuggestionPanel(in window: UIWindow) {
            guard let panel = suggestionPanel, !panel.isHidden else { return }
            let margin: CGFloat = 8
            let h = panel.preferredHeight
            let bottom = keyboardTopY > 0 ? keyboardTopY : window.bounds.height
            panel.frame = CGRect(x: margin, y: bottom - h,
                                 width: window.bounds.width - margin * 2, height: h)
        }

        /// 本文の下インセットを「キーボード被り＋（候補表示中はパネル高さ）」に設定する。
        /// パネル分を足すことで、カーソルがパネルに隠れず真上に来るまでスクロールできる。
        private func applyBottomInset() {
            guard let tv = textView else { return }
            let panelH = (suggestionPanel?.isHidden == false) ? (suggestionPanel?.preferredHeight ?? 0) : 0
            tv.contentInset.bottom = keyboardOverlap + panelH
            tv.verticalScrollIndicatorInsets.bottom = keyboardOverlap
        }

        // MARK: ツールバーアクション

        func handlePaste() {
            guard let tv = textView else { return }

            // 画像優先（スクショ等はテキスト表現も併せ持つことがあるため先に判定）。
            // クリップボードに画像があれば、プレースホルダを即挿入して裏で Gyazo にアップロードする。
            if UIPasteboard.general.hasImages, let payload = imagePayloadFromPasteboard() {
                let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
                guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    presentAlert(title: "Gyazo 未設定",
                                 message: "設定 →「画像アップロード（Gyazo）」でアクセストークンを登録してください。")
                    return
                }
                uploadWithPlaceholder(data: payload.data, filename: payload.filename,
                                      mimeType: payload.mimeType, at: tv.selectedRange.location)
                return
            }

            guard let pasteText = UIPasteboard.general.string, !pasteText.isEmpty else { return }
            tv.insertText(pasteText)   // textViewDidChange 経由でスタイリングと parent.text 反映
        }

        // MARK: 画像アップロード（Gyazo）

        /// 画像ピッカーで選んだ写真を Gyazo にアップロードし、カーソル位置に `![](url)` を挿入する。
        func handleUploadImage() {
            guard let tv = textView else { return }
            let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentAlert(title: "Gyazo 未設定",
                             message: "設定 →「画像アップロード（Gyazo）」でアクセストークンを登録してください。")
                return
            }
            // ピッカー表示でフォーカスが外れる前にカーソル位置を控える
            savedImageInsertLocation = tv.selectedRange.location

            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            topViewController()?.present(picker, animated: true)
        }

        /// クリップボードの画像をアップロード用データに変換する。
        /// スクショ等の PNG は再エンコードせずそのまま使い、透過・文字の鮮明さを保つ。
        /// 無ければ UIImage から JPEG(0.85) にフォールバック。
        private func imagePayloadFromPasteboard() -> (data: Data, filename: String, mimeType: String)? {
            let pb = UIPasteboard.general
            if let png = pb.data(forPasteboardType: "public.png") {
                return (png, "image.png", "image/png")
            }
            if let image = pb.image, let jpeg = image.jpegData(compressionQuality: 0.85) {
                return (jpeg, "image.jpg", "image/jpeg")
            }
            return nil
        }

        /// `![アップロード中…]()` プレースホルダを即挿入し、裏で Gyazo にアップロード。
        /// 完了で本文中の同プレースホルダを `![](url)` に差し替える（失敗時は除去＋アラート）。
        private func uploadWithPlaceholder(data: Data, filename: String, mimeType: String, at location: Int) {
            // UUID で一意化。連続ペーストや置換待ち中の編集があっても取り違えない。
            let placeholder = "![アップロード中…](upload://\(UUID().uuidString))"
            insertPlaceholder(placeholder, at: location)
            Task { @MainActor in
                let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
                do {
                    let url = try await GyazoUploadService.upload(
                        imageData: data, filename: filename, mimeType: mimeType, token: token)
                    replacePlaceholder(placeholder, with: "![](\(url))")
                } catch {
                    replacePlaceholder(placeholder, with: "")   // 失敗：プレースホルダを取り除く
                    presentAlert(title: "アップロード失敗", message: error.localizedDescription)
                }
            }
        }

        /// 指定位置にプレースホルダ文字列を挿入し、カーソルをその直後へ。
        private func insertPlaceholder(_ placeholder: String, at location: Int) {
            guard let tv = textView else { return }
            let loc = clamp(location, in: tv)

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: NSRange(location: loc, length: 0), with: placeholder)
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: loc + (placeholder as NSString).length, length: 0)
            applyStylingAfterEdit(tv)
        }

        /// 本文中のプレースホルダ文字列を検索して置換する。
        /// ユーザが既に消していたら（見つからなければ）何もしない。
        private func replacePlaceholder(_ placeholder: String, with replacement: String) {
            guard let tv = textView else { return }
            let range = (tv.text as NSString).range(of: placeholder)
            guard range.location != NSNotFound else { return }

            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: range, with: replacement)
            tv.textStorage.endEditing()

            // カーソルがプレースホルダより後ろにあれば、長さ差ぶん補正してズレを防ぐ。
            let delta = (replacement as NSString).length - range.length
            let sel = tv.selectedRange
            if sel.location >= range.location + range.length {
                tv.selectedRange = NSRange(location: max(0, sel.location + delta), length: sel.length)
            }
            applyStylingAfterEdit(tv)
        }

        /// 最前面のビューコントローラ（ピッカー／アラート提示用）。
        private func topViewController() -> UIViewController? {
            var top = textView?.window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }

        private func presentAlert(title: String, message: String) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topViewController()?.present(alert, animated: true)
        }

        // MARK: PHPickerViewControllerDelegate

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            let location = savedImageInsertLocation   // ピッカーを開いた時点のカーソル位置
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self,
                      let image = object as? UIImage,
                      let data  = image.jpegData(compressionQuality: 0.85) else { return }
                Task { @MainActor in
                    self.uploadWithPlaceholder(data: data, filename: "image.jpg",
                                               mimeType: "image/jpeg", at: location)
                }
            }
        }

        /// `[[]]` を挿入する。選択範囲があれば囲む。
        func handleDoubleBracket() {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            let ns    = tv.text as NSString
            let selected = ns.substring(with: range)
            let inserted = "[[\(selected)]]"

            registerStructuralUndo(tv)
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

        /// 既存のリストマーカー長を返す（無ければ 0）。
        private func listMarkerLength(_ stripped: String) -> Int {
            if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("- [x]")
                || stripped.hasPrefix("* [ ]") || stripped.hasPrefix("* [x]") { return 6 }
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") { return 2 }
            return 0
        }

        /// 現在の行（タブ除去後）に対する「次の状態」のマーカーと、旧マーカー長を返す。
        /// リスト → チェックボックス → 完了 → リスト の 3 状態サイクル。プレーンは `- ` で開始。
        private func nextListMarker(for stripped: String) -> (marker: String, oldLen: Int) {
            if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("* [ ]") {
                return ("\(stripped.prefix(1)) [x] ", 6)
            } else if stripped.hasPrefix("- [x]") || stripped.hasPrefix("* [x]") {
                return ("\(stripped.prefix(1)) ", 6)
            } else if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") {
                return ("\(stripped.prefix(1)) [ ] ", 2)
            } else if stripped.hasPrefix("+ ") {
                return ("- [ ] ", 2)
            } else {
                return ("- ", 0)
            }
        }

        /// 行文字列をタブ部分と本体に分解する（末尾改行は除く）。
        private func splitTabs(_ line: String) -> (tabs: String, stripped: String) {
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let tabs = String(body.prefix(while: { $0 == "\t" }))
            return (tabs, String(body.dropFirst(tabs.count)))
        }

        /// リスト → チェックボックス → 完了 → リスト の 3 状態トグル。
        /// プレーン行の場合は `- ` を付与してサイクルに入る。
        func handleListToggle() {
            guard let tv = textView else { return }
            if let block = multilineBlock(in: tv) {
                listToggleBlock(tv, block: block); return
            }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            var line      = ns.substring(with: lineRange)
            let hasNewline = line.hasSuffix("\n")
            if hasNewline { line = String(line.dropLast()) }

            let tabs     = String(line.prefix(while: { $0 == "\t" }))
            let stripped = String(line.dropFirst(tabs.count))

            let (newMarker, oldMarkerLen) = nextListMarker(for: stripped)

            let body = String(stripped.dropFirst(oldMarkerLen))
            let newLine = tabs + newMarker + body + (hasNewline ? "\n" : "")

            registerStructuralUndo(tv)
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

        /// 選択ブロック内の各行を、先頭の非空行から決めた同じマーカーに統一する。
        private func listToggleBlock(_ tv: UITextView, block: NSRange) {
            let ns    = tv.text as NSString
            let lines = lineRanges(in: block, ns: ns)

            // マーカーの基準にする先頭の非空行を探す
            guard let firstContentLine = lines.first(where: {
                !splitTabs(ns.substring(with: $0)).stripped.trimmingCharacters(in: .whitespaces).isEmpty
            }) else { return }
            let target = nextListMarker(for: splitTabs(ns.substring(with: firstContentLine)).stripped).marker

            var result = ""
            for lr in lines {
                let lineStr = ns.substring(with: lr)
                let (tabs, stripped) = splitTabs(lineStr)
                if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                    result += lineStr   // 空行はそのまま
                    continue
                }
                let body = String(stripped.dropFirst(listMarkerLength(stripped)))
                result += tabs + target + body + (lineStr.hasSuffix("\n") ? "\n" : "")
            }

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: block, with: result)
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: block.location, length: (result as NSString).length)
            applyStylingAfterEdit(tv)
        }

        func handleMoveLineUp() {
            guard let tv = textView else { return }
            if let block = multilineBlock(in: tv) {
                moveBlockUp(tv, block: block); return
            }
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

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: combined, with: newContent)
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: clamp(prevRange.location + cursorInCurr, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        /// 選択ブロックを 1 行上へ移動し、移動後もブロックを選択状態に保つ。
        private func moveBlockUp(_ tv: UITextView, block: NSRange) {
            let ns = tv.text as NSString
            guard block.location > 0 else { return }
            let prevRange = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))

            let prevBody  = String(ns.substring(with: prevRange).dropLast())   // 直前行は必ず \n 終わり
            let blockText = ns.substring(with: block)
            let blockHasNL = blockText.hasSuffix("\n")
            let blockBody  = blockHasNL ? String(blockText.dropLast()) : blockText

            let newContent = blockBody + "\n" + prevBody + (blockHasNL ? "\n" : "")
            let combined = NSRange(location: prevRange.location,
                                   length: prevRange.length + block.length)

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: combined, with: newContent)
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: prevRange.location, length: block.length)
            applyStylingAfterEdit(tv)
        }

        /// 選択ブロックを 1 行下へ移動し、移動後もブロックを選択状態に保つ。
        private func moveBlockDown(_ tv: UITextView, block: NSRange) {
            let ns = tv.text as NSString
            let nextStart = block.location + block.length
            guard nextStart < ns.length else { return }
            let nextRange = ns.lineRange(for: NSRange(location: nextStart, length: 0))

            let blockBody = String(ns.substring(with: block).dropLast())   // 次行があるので必ず \n 終わり
            let nextText  = ns.substring(with: nextRange)
            let nextHasNL = nextText.hasSuffix("\n")
            let nextBody  = nextHasNL ? String(nextText.dropLast()) : nextText

            let newContent = nextBody + "\n" + blockBody + (nextHasNL ? "\n" : "")
            let combined = NSRange(location: block.location,
                                   length: block.length + nextRange.length)

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: combined, with: newContent)
            tv.textStorage.endEditing()

            let newBlockStart = block.location + (nextBody as NSString).length + 1
            tv.selectedRange = NSRange(location: newBlockStart, length: block.length)
            applyStylingAfterEdit(tv)
        }

        func handleMoveLineDown() {
            guard let tv = textView else { return }
            if let block = multilineBlock(in: tv) {
                moveBlockDown(tv, block: block); return
            }
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

            registerStructuralUndo(tv)
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
            if let block = multilineBlock(in: tv) {
                outdentBlock(tv, block: block); return
            }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let line      = ns.substring(with: lineRange)
            guard line.hasPrefix("\t") else { return }

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: "")
            tv.textStorage.endEditing()

            let newCursor = max(lineRange.location, cursorLoc - 1)
            tv.selectedRange = NSRange(location: clamp(newCursor, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        func handleIncreaseIndent() {
            guard let tv = textView else { return }
            if let block = multilineBlock(in: tv) {
                indentBlock(tv, block: block); return
            }
            let ns        = tv.text as NSString
            let cursorLoc = tv.selectedRange.location
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            tv.textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: "\t")
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: clamp(cursorLoc + 1, in: tv), length: 0)
            applyStylingAfterEdit(tv)
        }

        /// 選択ブロック内の各行頭にタブを追加し、ブロックを選択状態に保つ。
        private func indentBlock(_ tv: UITextView, block: NSRange) {
            let ns    = tv.text as NSString
            let lines = lineRanges(in: block, ns: ns)

            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            for lr in lines.reversed() {
                tv.textStorage.replaceCharacters(in: NSRange(location: lr.location, length: 0), with: "\t")
            }
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: block.location, length: block.length + lines.count)
            applyStylingAfterEdit(tv)
        }

        /// 選択ブロック内の各行頭からタブを 1 つ削除し、ブロックを選択状態に保つ。
        private func outdentBlock(_ tv: UITextView, block: NSRange) {
            let ns    = tv.text as NSString
            let lines = lineRanges(in: block, ns: ns)
            guard lines.contains(where: { ns.substring(with: $0).hasPrefix("\t") }) else { return }

            var removed = 0
            registerStructuralUndo(tv)
            tv.textStorage.beginEditing()
            for lr in lines.reversed() where ns.substring(with: lr).hasPrefix("\t") {
                tv.textStorage.replaceCharacters(in: NSRange(location: lr.location, length: 1), with: "")
                removed += 1
            }
            tv.textStorage.endEditing()

            tv.selectedRange = NSRange(location: block.location,
                                       length: max(0, block.length - removed))
            applyStylingAfterEdit(tv)
        }

        // MARK: ツールバーアクション共通ユーティリティ

        private func applyStylingAfterEdit(_ tv: UITextView) {
            MarkdownStyler.apply(to: tv.textStorage, notes: notes,
                                 fontSize: fontSize, lineSpacing: lineSpacing)
            parent.text = tv.text
            tv.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        }

        /// 画像読み込み完了時：余白（段落スタイル）を更新し、オーバーレイを再配置させる。
        func reapplyStylingForImageLoad() {
            guard let tv = textView else { return }
            MarkdownStyler.apply(to: tv.textStorage, notes: notes,
                                 fontSize: fontSize, lineSpacing: lineSpacing)
            (tv as? NonAutoScrollTextView)?.invalidateImagePreviews()
        }

        private func clamp(_ loc: Int, in tv: UITextView) -> Int {
            max(0, min(loc, tv.text.utf16.count))
        }

        /// 構造編集の前に呼ぶ。textStorage の直接編集は UITextView 標準の UndoManager に
        /// 乗らないため、操作前の本文全体と選択範囲を控え、「1操作＝1ステップ」で巻き戻せる
        /// undo を登録する。undo 実行時に現在状態を再登録することで redo も成立する。
        private func registerStructuralUndo(_ tv: UITextView) {
            let beforeText = tv.text ?? ""
            let beforeSel  = tv.selectedRange
            tv.undoManager?.registerUndo(withTarget: self) { coord in
                guard let tv = coord.textView else { return }
                coord.registerStructuralUndo(tv)   // redo 用に「今の状態」を登録してから巻き戻す
                tv.text = beforeText
                let len = (beforeText as NSString).length
                let loc = max(0, min(beforeSel.location, len))
                tv.selectedRange = NSRange(location: loc, length: max(0, min(beforeSel.length, len - loc)))
                coord.applyStylingAfterEdit(tv)     // 再スタイル＋ parent.text 反映
            }
        }

        // MARK: 複数行選択ユーティリティ

        /// 選択範囲を行頭〜行末に拡張したブロック範囲。
        /// 選択末尾がちょうど行頭の場合、その行は含めない（一般的なエディタと同じ）。
        private func selectedLinesRange(in tv: UITextView) -> NSRange {
            let ns  = tv.text as NSString
            let sel = tv.selectedRange
            let startLine = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let endLoc = sel.location + sel.length
            let probe  = (sel.length > 0 && endLoc > startLine.location) ? endLoc - 1 : endLoc
            let endLine = ns.lineRange(for: NSRange(location: min(probe, ns.length), length: 0))
            return NSRange(location: startLine.location,
                           length: endLine.location + endLine.length - startLine.location)
        }

        /// ブロック内の各行の NSRange（末尾改行を含む）。
        private func lineRanges(in block: NSRange, ns: NSString) -> [NSRange] {
            var ranges: [NSRange] = []
            var loc = block.location
            let end = block.location + block.length
            while loc < end {
                let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
                ranges.append(lr)
                loc = lr.location + lr.length
                if lr.length == 0 { break }
            }
            return ranges
        }

        /// 複数行を選択しているときだけブロック範囲を返す。単一行・カーソルのみなら nil。
        private func multilineBlock(in tv: UITextView) -> NSRange? {
            guard tv.selectedRange.length > 0 else { return nil }
            let ns    = tv.text as NSString
            let block = selectedLinesRange(in: tv)
            return lineRanges(in: block, ns: ns).count > 1 ? block : nil
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
            registerStructuralUndo(tv)
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
            keyboardOverlap = max(0, tvMaxY - kbFrame.minY)
            keyboardTopY    = kbFrame.minY   // 候補パネルの基準（キーボード／アクセサリ上端）

            applyBottomInset()
            positionSuggestionPanel(in: window)   // 表示中なら追従配置
            revealCaretIfHidden(in: tv)
        }

        @objc func keyboardWillHide(_ notification: Notification) {
            keyboardOverlap = 0
            keyboardTopY = 0
            hideSuggestionPanel()   // 内部で applyBottomInset()（＝0）も実行
        }

        /// 直近の選択範囲。選択操作でどちらの端（開始／終了）が動いたか判定するため保持する。
        private var lastSelectedRange = NSRange(location: 0, length: 0)

        /// 1点（caret rect）が上下に隠れそうな時だけ、その点を最小限スクロールして見せる。
        /// scrollRectToVisible は使わず contentOffset を直接設定するため、自動スクロール抑制と両立する。
        private func revealCaret(_ caret: CGRect, in tv: UITextView) {
            guard caret.maxY.isFinite, caret.minY.isFinite else { return }

            let bottomPadding: CGFloat = 60   // キーボード上端からの余白
            let topPadding:    CGFloat = 24   // ヘッダー側の余白
            let topInset      = tv.contentInset.top
            let bottomInset   = tv.contentInset.bottom        // キーボードが隠している高さ
            let visibleHeight = tv.bounds.height - topInset - bottomInset
            let visibleTop    = tv.contentOffset.y + topInset
            let visibleBottom = tv.contentOffset.y + topInset + visibleHeight
            let maxOffsetY    = max(0, tv.contentSize.height + bottomInset - tv.bounds.height)

            if caret.maxY + bottomPadding > visibleBottom {
                // 下（キーボード側）に隠れそう → 下へスクロール（下方向のみ）
                let targetY = min(caret.maxY + bottomPadding - topInset - visibleHeight, maxOffsetY)
                if targetY > tv.contentOffset.y { tv.contentOffset.y = targetY }
            } else if caret.minY - topPadding < visibleTop {
                // 上（ヘッダー側）に隠れそう → 上へスクロール（上方向のみ）
                let targetY = max(0, caret.minY - topPadding - topInset)
                if targetY < tv.contentOffset.y { tv.contentOffset.y = targetY }
            }
        }

        /// 挿入点（選択の end）を見せる。入力・改行・キーボード表示で使う。
        private func revealCaretIfHidden(in tv: UITextView) {
            guard let range = tv.selectedTextRange else { return }
            lastSelectedRange = tv.selectedRange
            revealCaret(tv.caretRect(for: range.end), in: tv)
        }

        /// 選択変更時：直前と比べて「動いた側の端」だけを追従する。
        /// 開始ハンドルを動かしている時は終了側の補正をしない（逆も同様）ので、思う方向へ広げられる。
        private func revealActiveCaret(in tv: UITextView) {
            guard let sel = tv.selectedTextRange else { return }
            let new = tv.selectedRange
            let old = lastSelectedRange
            lastSelectedRange = new

            let newStart = new.location, newEnd = new.location + new.length
            let oldStart = old.location, oldEnd = old.location + old.length

            let position: UITextPosition
            if new.length == 0 {
                position = sel.end                                   // 単一カーソル
            } else if newStart != oldStart && newEnd == oldEnd {
                position = sel.start                                 // 開始ハンドルを操作中
            } else if newEnd != oldEnd && newStart == oldStart {
                position = sel.end                                   // 終了ハンドルを操作中
            } else {
                position = sel.end                                   // 判定不能時は終了側
            }
            revealCaret(tv.caretRect(for: position), in: tv)
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            updateSuggestions(for: textView)
        }

        // MARK: リスト自動補完

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // 編集後の変更範囲（位置＋置換テキスト長）を控え、textViewDidChange で部分再スタイルに使う
            pendingChangeRange = NSRange(location: range.location, length: (text as NSString).length)
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

            registerStructuralUndo(textView)
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
            // 打鍵時は変更段落だけ再スタイル（programmatic 編集では全体 apply にフォールバック）
            if let changed = pendingChangeRange {
                MarkdownStyler.applyIncremental(to: textView.textStorage, changed: changed,
                                                notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            } else {
                MarkdownStyler.apply(to: textView.textStorage, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
            }
            pendingChangeRange = nil
            isStyling = false

            parent.text = textView.text
            textView.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            updateSuggestions(for: textView)
            revealCaretIfHidden(in: textView)   // Phase 4: 入力・改行でカーソルが隠れたら見せる
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isStyling else { return }
            updateSuggestions(for: textView)
            // カーソル移動・選択範囲調整で、動いた側の端だけを最小限追従スクロール
            revealActiveCaret(in: textView)
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

            registerStructuralUndo(tv)
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

