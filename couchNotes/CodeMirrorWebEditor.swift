//
//  CodeMirrorWebEditor.swift
//  couchNotes
//
//  WKWebView + CodeMirror 6 のノートエディタ（couchnotes-vscode の webview ロジックを移植）。
//  TextKit1 の Mac 矢印キー不具合・iPhone 長押し選択飛びを回避するための新エディタ。
//  設定「新エディタを使う」で MarkdownTextView と切り替える。
//

import SwiftUI
import WebKit

/// 自前のキーボード上ツールバー（SwiftUIのフローティングビュー）から CodeMirror 側の
/// コマンドを実行するための橋渡し。inputAccessoryView を使わない代わりに、
/// evaluateJavaScript で直接コマンドを叩く。
@MainActor
final class WebEditorBridge: ObservableObject {
    fileprivate weak var webView: WKWebView?

    /// エディタ（contenteditable）がフォーカスを持っているか。キーボードツールバーの表示制御用。
    @Published var isEditorFocused = false

    /// アップロード失敗など、ユーザーへ見せたいエラー。
    var onError: ((String) -> Void)?

    /// キーボードツールバーのコマンド（wikiLink / listToggle / moveLineUp / moveLineDown / indent / outdent）
    func run(_ command: String) {
        webView?.evaluateJavaScript("window.couchNotesRunCommand('\(command)');")
    }

    /// キーボードを閉じる（ツールバーの閉じるボタン用）。
    func dismissKeyboard() {
        webView?.endEditing(true)
    }

    fileprivate func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.couchNotesReceive(\(json));")
    }

    /// カーソル位置にテキストを挿入する（ユーザー編集としてエコーされ、保存フローに乗る）。
    func insertText(_ text: String) {
        send(["type": "insertText", "text": text])
    }

    /// ツールバーの「ペースト」。画像優先で Gyazo にアップロードし、テキストはそのまま挿入する。
    func pasteFromClipboard() {
        if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image,
           let data = image.jpegData(compressionQuality: 0.9) {
            uploadImage(data: data, mime: "image/jpeg", filename: "image.jpg")
        } else if let text = UIPasteboard.general.string {
            insertText(text)
        }
    }

    /// 画像データを Gyazo にアップロードして ![](url) を挿入する（写真ボタン・ペースト共通）。
    /// プレースホルダを即挿入し、完了後に URL へ置換する（既存 UX と同じ）。
    func uploadImage(data: Data, mime: String, filename: String) {
        let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            onError?("Gyazo アクセストークンが未設定です。設定 →「画像アップロード（Gyazo）」で登録してください。")
            return
        }
        webView?.evaluateJavaScript("window.couchNotesInsertPlaceholder();") { [weak self] result, _ in
            guard let self, let id = result as? String else { return }
            Task { @MainActor in
                do {
                    let url = try await GyazoUploadService.upload(
                        imageData: data, filename: filename, mimeType: mime, token: token)
                    self.send(["type": "pasteResult", "id": id, "url": url])
                } catch {
                    self.send(["type": "pasteResult", "id": id])   // プレースホルダ除去
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    /// Web 側 paste イベント発の画像（base64）をアップロードする。
    fileprivate func handleWebPaste(id: String, mime: String, base64: String, filename: String) {
        guard let data = Data(base64Encoded: base64) else {
            send(["type": "pasteResult", "id": id])
            return
        }
        let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            send(["type": "pasteResult", "id": id])
            onError?("Gyazo アクセストークンが未設定です。設定 →「画像アップロード（Gyazo）」で登録してください。")
            return
        }
        Task { @MainActor in
            do {
                let url = try await GyazoUploadService.upload(
                    imageData: data, filename: filename, mimeType: mime, token: token)
                send(["type": "pasteResult", "id": id, "url": url])
            } catch {
                send(["type": "pasteResult", "id": id])
                onError?(error.localizedDescription)
            }
        }
    }
}

/// ブロック参照リンク（[[ページ#^ID]]）の遷移後スクロール先。
/// リンクタップ時に積み、遷移先エディタの ready 時に消費して該当行へスクロールする。
/// 画面をまたぐ受け渡しのため（タップ元と遷移先は別のエディタインスタンス）ここに置く。
@MainActor
enum BlockLinkTarget {
    static var pendingBlockId: String?
}

/// シェイク Undo／3本指ジェスチャ用のプロキシ NSUndoManager。
/// 実際の履歴は CodeMirror が持つため、深さ（可否）だけを映し、
/// 実行はブリッジ経由で CM の undo/redo コマンドへ委譲する。
final class WebEditorUndoManager: UndoManager {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var cmCanUndo = false
    var cmCanRedo = false

    override var canUndo: Bool { cmCanUndo }
    override var canRedo: Bool { cmCanRedo }
    override func undo() { onUndo?() }
    override func redo() { onRedo?() }
}

private var webEditorUndoManagerKey: UInt8 = 0

/// WKWebView 内部のコンテンツビュー（WKContent*）に対するランタイム調整。
/// 公開 API が無い2点を、ランタイム生成サブクラスのメソッド上書きで実現する
/// （非公開 API の呼び出しはしない、広く使われている確立済みの手法）:
/// 1. inputAccessoryView → nil（フォームアシスタントバーを消し、自前ツールバーで代替）
/// 2. undoManager → プロキシ（シェイク Undo／3本指ジェスチャを CodeMirror の履歴に接続）
private enum SystemAccessoryRemover {
    private static func contentView(of webView: WKWebView) -> UIView? {
        webView.scrollView.subviews.first {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }
    }

    static func remove(from webView: WKWebView) {
        guard let target = contentView(of: webView) else { return }

        let className = "WKContentView_CouchNotesNoAccessory"
        var cls: AnyClass? = NSClassFromString(className)
        if cls == nil, let targetClass = object_getClass(target) {
            cls = objc_allocateClassPair(targetClass, className, 0)
            if let cls {
                let accessorySel = #selector(getter: UIResponder.inputAccessoryView)
                let accessoryBlock: @convention(block) (AnyObject) -> UIView? = { _ in nil }
                class_addMethod(cls, accessorySel,
                                imp_implementationWithBlock(accessoryBlock), "@@:")

                // undoManager: 関連オブジェクトに積んだプロキシを返す（未設定なら nil = 既定の探索へ）
                let undoSel = #selector(getter: UIResponder.undoManager)
                let undoBlock: @convention(block) (AnyObject) -> Any? = { obj in
                    objc_getAssociatedObject(obj, &webEditorUndoManagerKey)
                }
                class_addMethod(cls, undoSel,
                                imp_implementationWithBlock(undoBlock), "@@:")

                objc_registerClassPair(cls)
            }
        }
        if let cls { object_setClass(target, cls) }
    }

    /// プロキシ UndoManager をコンテンツビューに関連付ける（remove の後に呼ぶ）。
    static func attachUndoManager(_ manager: WebEditorUndoManager, to webView: WKWebView) {
        guard let target = contentView(of: webView) else { return }
        objc_setAssociatedObject(target, &webEditorUndoManagerKey, manager,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

struct CodeMirrorWebEditor: UIViewRepresentable {
    @Binding var text: String
    var wikiTargets: [String] = []
    var mentionedTargets: [String] = []   // 言及のみの未作成ページ名（サジェスト専用）
    var fontSize: CGFloat = 16
    var lineSpacing: CGFloat = 0
    var horizontalInset: CGFloat = 0   // テキストの左右内側余白（Mac・ランドスケープ用）
    var fontCSSURL: String = ""        // Web フォントの CSS URL（Google Fonts 等。空=無効）
    var fontFamily: String = ""        // 適用する font-family 名（空=システムフォント）
    var livePreview: Bool = false      // 記法隠し（カーソル行以外はプレビュー表示）
    var backlinks: [NoteItem] = []
    var twoHop: [TwoHopGroup] = []
    var footerLayout: String = "list"  // "list" | "grid"
    var bridge: WebEditorBridge? = nil
    var onLinkTap: ((String) -> Void)? = nil
    var onFooterLayoutChange: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "couchNotes")
        // ページ自身のどのスクリプト（webview.js）よりも先に、本文・余白・文字サイズ等の
        // 初期値を window.__couchNotesInit として注入する。WKWebView 標準の仕組みなので
        // ファイル書き込み・loadHTMLString は不要で、通常の loadFileURL のまま使える。
        // これにより Swift→JS の通信往復（ready→init）を待たずに最初の描画から正しい状態になる
        // （見出し・リストと同じタイミングで余白・文字サイズも反映される）。
        if let initScript = Self.initUserScript(payload: initialConfigPayload()) {
            config.userContentController.addUserScript(initScript)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true   // Safari の Web Inspector で検証できるようにする（デバッグ用）
        // アプリの背景（ライト/ダーク）を透過で見せる
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 下スワイプでキーボードを畳めるようにする（旧エディタと同じ）
        webView.scrollView.keyboardDismissMode = .interactive
        context.coordinator.webView = webView
        bridge?.webView = webView

        SystemAccessoryRemover.remove(from: webView)
        SystemAccessoryRemover.attachUndoManager(context.coordinator.undoProxy, to: webView)

        if let dir = Self.resourceDirectory() {
            let index = dir.appendingPathComponent("index.html")
            webView.loadFileURL(index, allowingReadAccessTo: dir)
        }
        return webView
    }

    /// 初期化メッセージと同じ内容（本文・余白・文字サイズ等）を、ページ読み込み前の
    /// JS 変数として渡すためのペイロード。Coordinator の docVersion 初期値（1）と揃える。
    private func initialConfigPayload() -> [String: Any] {
        [
            "text": text,
            "wikiTargets": wikiTargets,
            "mentionedTargets": mentionedTargets,
            "fontSize": fontSize,
            "lineSpacing": lineSpacing,
            "horizontalInset": horizontalInset,
            "fontCSSURL": fontCSSURL,
            "fontFamily": fontFamily,
            "livePreview": livePreview,
            "version": 1,
        ]
    }

    /// `window.__couchNotesInit = {...}` を文書解析開始時に注入する UserScript を作る。
    private static func initUserScript(payload: [String: Any]) -> WKUserScript? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else { return nil }
        // 本文中に "</script>" が含まれていても、注入先で誤解釈されないようにする
        json = json.replacingOccurrences(of: "</", with: "<\\/")
        let source = "window.__couchNotesInit = \(json);"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.isReady, !context.coordinator.isApplyingRemoteEdit else { return }
        context.coordinator.pushExternalUpdateIfNeeded(text)
        context.coordinator.pushConfigIfNeeded(fontSize: fontSize, lineSpacing: lineSpacing,
                                               horizontalInset: horizontalInset,
                                               fontCSSURL: fontCSSURL, fontFamily: fontFamily,
                                               livePreview: livePreview)
        context.coordinator.pushWikiTargetsIfNeeded(wikiTargets, mentioned: mentionedTargets)
        context.coordinator.pushFooterIfNeeded(backlinks: backlinks, twoHop: twoHop, layout: footerLayout)
    }

    /// WebEditor リソース（index.html / webview.js / webview.css）のディレクトリを探す。
    /// Xcode 16 のフォルダ同期グループはサブフォルダ構成をそのままバンドルへ反映するため、
    /// サブディレクトリ指定と非指定の両方を試す。
    private static func resourceDirectory() -> URL? {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebEditor") {
            return url.deletingLastPathComponent()
        }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CodeMirrorWebEditor
        weak var webView: WKWebView?
        var isReady = false
        var isApplyingRemoteEdit = false
        private var lastSentText: String?
        private var lastFontSize: CGFloat?
        private var lastLineSpacing: CGFloat?
        private var lastHorizontalInset: CGFloat?
        private var lastWikiTargets: [String] = []
        /// 文書の世代番号。外部更新（同期反映）で JS 側の文書を差し替えるたびに上げ、
        /// それより古い世代に基づく編集メッセージは破棄する（同期との交差による本文破壊防止）。
        private var docVersion = 1

        /// シェイク Undo／3本指ジェスチャを CM の履歴へ橋渡しするプロキシ。
        let undoProxy = WebEditorUndoManager()

        init(_ parent: CodeMirrorWebEditor) {
            self.parent = parent
            super.init()
            undoProxy.onUndo = { [weak self] in
                self?.webView?.evaluateJavaScript("window.couchNotesRunCommand('undo');")
            }
            undoProxy.onRedo = { [weak self] in
                self?.webView?.evaluateJavaScript("window.couchNotesRunCommand('redo');")
            }
        }

        /// JS 側 loading 完了後の "ready" 受信で初回テキストを送る。以降 text が外部から
        /// 変わった時だけ pushExternalUpdateIfNeeded 経由で送り直す（打鍵エコー防止）。
        func pushExternalUpdateIfNeeded(_ text: String) {
            guard lastSentText != text else { return }
            lastSentText = text
            docVersion += 1
            send(type: "externalUpdate", extra: ["text": text, "version": docVersion])
        }

        private var lastFontCSSURL: String?
        private var lastFontFamily: String?
        private var lastLivePreview: Bool?

        func pushConfigIfNeeded(fontSize: CGFloat, lineSpacing: CGFloat, horizontalInset: CGFloat,
                                fontCSSURL: String, fontFamily: String, livePreview: Bool) {
            guard lastFontSize != fontSize || lastLineSpacing != lineSpacing
                    || lastHorizontalInset != horizontalInset
                    || lastFontCSSURL != fontCSSURL || lastFontFamily != fontFamily
                    || lastLivePreview != livePreview else { return }
            lastFontSize = fontSize
            lastLineSpacing = lineSpacing
            lastHorizontalInset = horizontalInset
            lastFontCSSURL = fontCSSURL
            lastFontFamily = fontFamily
            lastLivePreview = livePreview
            send(type: "config", extra: [
                "fontSize": fontSize, "lineSpacing": lineSpacing, "horizontalInset": horizontalInset,
                "fontCSSURL": fontCSSURL, "fontFamily": fontFamily,
                "livePreview": livePreview,
            ])
        }

        private var lastMentionedTargets: [String] = []

        func pushWikiTargetsIfNeeded(_ targets: [String], mentioned: [String]) {
            guard targets != lastWikiTargets || mentioned != lastMentionedTargets else { return }
            lastWikiTargets = targets
            lastMentionedTargets = mentioned
            send(type: "wikiTargets", extra: ["targets": targets, "mentioned": mentioned])
        }

        private var lastFooterJSON: String?

        func pushFooterIfNeeded(backlinks: [NoteItem], twoHop: [TwoHopGroup], layout: String) {
            let payload = Self.footerPayload(backlinks: backlinks, twoHop: twoHop, layout: layout)
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8),
                  json != lastFooterJSON else { return }
            lastFooterJSON = json
            send(type: "footer", extra: ["data": payload])
        }

        private static func footerPayload(backlinks: [NoteItem], twoHop: [TwoHopGroup],
                                          layout: String) -> [String: Any] {
            func noteDict(_ n: NoteItem) -> [String: Any] {
                var d: [String: Any] = ["id": n.id, "title": n.shortTitle]
                if let p = n.preview, !p.isEmpty { d["preview"] = String(p.prefix(300)) }
                return d
            }
            return [
                "layout": layout,
                "backlinks": backlinks.map(noteDict),
                "twoHop": twoHop.map { g -> [String: Any] in
                    var d: [String: Any] = [
                        "targetTitle": g.targetTitle,
                        "notes": g.notes.map(noteDict),
                    ]
                    if let id = g.targetId { d["targetId"] = id }
                    return d
                },
            ]
        }

        private func send(type: String, extra: [String: Any] = [:]) {
            var payload: [String: Any] = ["type": type]
            payload.merge(extra) { _, new in new }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.couchNotesReceive(\(json));"
            webView?.evaluateJavaScript(js) { _, error in
                if let error { print("[CodeMirrorWebEditor] evaluateJavaScript error: \(error)") }
            }
        }

        // MARK: WKScriptMessageHandler（JS → Swift）

        func userContentController(_ userContentController: WKUserContentController,
                                    didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                lastSentText = parent.text
                lastFontSize = parent.fontSize
                lastLineSpacing = parent.lineSpacing
                lastHorizontalInset = parent.horizontalInset
                lastFontCSSURL = parent.fontCSSURL
                lastFontFamily = parent.fontFamily
                lastLivePreview = parent.livePreview
                lastWikiTargets = parent.wikiTargets
                lastMentionedTargets = parent.mentionedTargets
                send(type: "init", extra: [
                    "text": parent.text,
                    "wikiTargets": parent.wikiTargets,
                    "mentionedTargets": parent.mentionedTargets,
                    "fontSize": parent.fontSize,
                    "lineSpacing": parent.lineSpacing,
                    "horizontalInset": parent.horizontalInset,
                    "fontCSSURL": parent.fontCSSURL,
                    "fontFamily": parent.fontFamily,
                    "livePreview": parent.livePreview,
                    "version": docVersion,
                ])
                pushFooterIfNeeded(backlinks: parent.backlinks, twoHop: parent.twoHop,
                                   layout: parent.footerLayout)
                // ブロック参照リンク経由で開かれた場合、init の後に該当行へスクロールさせる
                if let blockId = BlockLinkTarget.pendingBlockId {
                    BlockLinkTarget.pendingBlockId = nil
                    send(type: "revealBlock", extra: ["id": blockId])
                }

            case "edit":
                // 全文＋世代番号方式（native の parent.text = textView.text と同等）。
                // 外部更新と入れ違いに届いた古い世代の編集は破棄する。
                guard let version = body["version"] as? Int, version == docVersion,
                      let full = body["text"] as? String else { return }
                isApplyingRemoteEdit = true
                lastSentText = full
                parent.text = full
                isApplyingRemoteEdit = false
                // シェイク Undo の有効/無効を CM の履歴深さに同期
                undoProxy.cmCanUndo = (body["undoDepth"] as? Int ?? 0) > 0
                undoProxy.cmCanRedo = (body["redoDepth"] as? Int ?? 0) > 0

            case "openWiki":
                guard let target = body["target"] as? String else { return }
                webView?.endEditing(true)   // キーボードを閉じてからナビゲート（native と同じ）
                // native（MarkdownStyler）と同じ形式に正規化: エイリアス・見出しを除き ".md" を付ける。
                // NoteListView 側の解決（完全一致 or "/名前.md" 後方一致）が .md 付き前提のため。
                var t = target
                if let bar  = t.firstIndex(of: "|") { t = String(t[..<bar]) }
                if let hash = t.firstIndex(of: "#") {
                    // ブロック参照（#^ID）は遷移先で該当行へスクロールするため取り出して積む
                    let frag = String(t[t.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                    if frag.hasPrefix("^"), frag.count > 1 {
                        BlockLinkTarget.pendingBlockId = String(frag.dropFirst())
                    }
                    t = String(t[..<hash])
                }
                t = t.trimmingCharacters(in: .whitespaces)
                if !t.lowercased().hasSuffix(".md") { t += ".md" }
                parent.onLinkTap?(t)

            case "openExternal":
                guard let urlStr = body["url"] as? String, let url = URL(string: urlStr) else { return }
                webView?.endEditing(true)
                UIApplication.shared.open(url)

            case "openNote":
                // フッター（リンク元・2ホップ）から。id は解決済みなのでそのまま渡す。
                guard let id = body["id"] as? String else { return }
                webView?.endEditing(true)
                parent.onLinkTap?(id)

            case "footerLayout":
                guard let value = body["value"] as? String else { return }
                parent.onFooterLayoutChange?(value)

            case "pasteImage":
                guard let id = body["id"] as? String,
                      let mime = body["mime"] as? String,
                      let data = body["data"] as? String else { return }
                let filename = body["filename"] as? String ?? "image.png"
                parent.bridge?.handleWebPaste(id: id, mime: mime, base64: data, filename: filename)

            case "copy":
                // WKWebView（Mac Catalyst）は clipboardData 経由のコピーがシステムの
                // ペーストボードへ正しく反映されないことがある（型は宣言されるが中身が
                // 空になる）ため、JS 側でテキストをこちらへ送らせて直接書き込む。
                guard let text = body["text"] as? String else { return }
                UIPasteboard.general.string = text

            case "focus":
                parent.bridge?.isEditorFocused = true
            case "blur":
                parent.bridge?.isEditorFocused = false

            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // WebKit プロセス再生成でコンテンツビューが作り直された場合に備えて再適用
            SystemAccessoryRemover.remove(from: webView)
            SystemAccessoryRemover.attachUndoManager(undoProxy, to: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[CodeMirrorWebEditor] load error: \(error)")
        }
    }
}
