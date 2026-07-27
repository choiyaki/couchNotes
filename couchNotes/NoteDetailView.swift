import SwiftUI
import Combine
import Network
import PhotosUI
import UIKit

extension Notification.Name {
    /// ローカル編集の保存が成功した時に投げる通知。userInfo["noteId"] に対象 ID。
    static let noteSaved = Notification.Name("couchNotes.noteSaved")
}

// 平常時（入力中・保存中・保存直後）は画面上に何も出さない。
// 表示するのは「サーバへまだ反映できていない」ことが続いている場合（.unsaved）だけにする。
// ローカルへの永続化は入力停止からごく短時間で完了するため、ユーザーが保存を意識する必要はない。
enum SaveStatus: Equatable {
    case idle
    case unsaved    // ネットワーク断・競合などでサーバへ未反映（次回オンライン時/再送で解消）
}

// MARK: - NetworkMonitor

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "couchNotes.NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}

struct NoteDetailView: View {
    let noteId: String
    var displayPath: String? = nil
    var notes: [NoteItem] = []
    var canGoBack:    Bool = false
    var canGoForward: Bool = false
    var onLinkTap:    ((String) -> Void)? = nil
    var onGoBack:     (() -> Void)? = nil
    var onGoForward:  (() -> Void)? = nil
    var onGoToList:   (() -> Void)? = nil
    var onMoved:      ((String) -> Void)? = nil   // 移動後の新しい noteId を親へ通知
    var onCreated:    ((String) -> Void)? = nil   // 新規作成したノートを開くため親へ通知
    var onSearchCommit: ((String) -> Void)? = nil // Enter：その語で一覧の本文検索を開く

    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0
    // 一覧へ戻るボタンのアイコンを一覧の表示モードに合わせる
    @AppStorage("noteList_layout")    private var layoutRaw = NoteListLayout.detail.rawValue
    // 新エディタ（CodeMirror/WKWebView）。TextKit1 の Mac 矢印キー・iPhone 選択飛び不具合の回避。
    @AppStorage("editor_useCodeMirror") private var useCodeMirror = false
    // Web フォント（新エディタのみ）
    @AppStorage("editor_webFontCSSURL") private var webFontCSSURL = ""
    @AppStorage("editor_webFontFamily") private var webFontFamily = ""
    // ライブプレビュー（記法隠し。新エディタのみ）
    @AppStorage("editor_livePreview") private var livePreview = true

    @ObservedObject private var network = NetworkMonitor.shared

    // 新エディタとのブリッジ（ツールバーコマンド・フォーカス状態・画像アップロード）
    @StateObject private var webBridge = WebEditorBridge()
    @State private var photoPickerItem: PhotosPickerItem? = nil
    // ピッカーの提示はフォーカス連動で消えるツールバーから切り離す（共有アルバム選択で
    // 親ビューごと破棄されて閉じるのを防ぐ）。提示元は常設の Group（下記）に置く。
    @State private var showPhotoPicker = false

    @State private var content        = ""
    @State private var editingContent = ""
    @State private var baseRev:       String? = nil   // 楽観ロックの基準 _rev（競合検知用）
    @State private var isLoading      = true
    // 保存の直列化（保存を二重に走らせない＝自分の保存を外部更新と誤検知しないため）
    @State private var saveInFlight   = false
    @State private var pendingSave    = false

    // フロントマター（YAML created/updated）。content/editingContent は本文のみ。
    @State private var createdMs:        Double? = nil
    @State private var updatedMs:        Double? = nil
    @State private var extraFrontmatter: String  = ""
    @State private var isRefreshing   = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var hasUnsavedChanges     = false

    // 外部更新バナー用
    @State private var externalChangeAvailable = false
    @State private var pendingExternalContent  = ""

    // メニュー（削除確認・削除後の保存抑止）
    @State private var showDeleteConfirm = false
    @State private var isDeletedNote     = false   // 削除後にデバウンス保存が走って復活するのを防ぐ

    // デバウンス保存用
    @State private var saveDebounceTask: Task<Void, Never>?
    // ローカル永続化（dirty書き込みのみ、ネットワーク送信はしない）用の短いデバウンス。
    // サーバへの push より先に成立させ、kill/バックグラウンド遷移で入力を失わないようにする。
    @State private var localSaveDebounceTask: Task<Void, Never>?

    // バックリンク（本文末尾に表示）
    @State private var backlinks: [NoteItem] = []
    // 2ホップリンク（新エディタのフッター用）
    @State private var twoHop: [TwoHopGroup] = []
    // 言及のみの未作成ページ名（[[ ]] サジェスト用）
    @State private var mentionedTargets: [String] = []
    // フッターの表示形式（リスト / グリッド）
    @AppStorage("backlinks_layout") private var backlinksLayout = "list"

    // 検索（詳細画面上：入力中はタイトル候補、Enter で一覧の本文検索へ）
    @State private var showSearch     = false
    @State private var searchText     = ""
    @State private var titleResults:  [NoteItem] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    // 画面サイズ（向き判定用）。ランドスケープのみ左右に余白を入れる。
    @State private var editorSize: CGSize = .zero
    private var landscapeSideInset: CGFloat {
        // 幅が広い（Mac・iPad・iPhone横向き）時だけ余白を入れる。
        // 高さだけで判定すると、キーボード表示で高さが縮んだ縦持ち iPhone を
        // 横向きと誤検知してタイトル等に余白が入ってしまう。
        guard editorSize.width > editorSize.height, editorSize.width >= 600 else { return 0 }
        return max(editorSize.width * 0.12, 48)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var showTitleDropdown: Bool {
        showSearch && !trimmedSearch.isEmpty && !titleResults.isEmpty
    }

    // フォルダ移動・新規作成
    @State private var showFolderPicker = false
    @State private var showNewNote      = false

    // 本文上のタイトル欄（編集するとファイル名＝タイトルがリネームされる）
    @State private var titleDraft       = ""
    @FocusState private var titleFocused: Bool

    /// 現在のフォルダ（正規化キー。ルートは nil）
    private var currentFolderKey: String? {
        let comps = noteId.components(separatedBy: "/")
        return comps.count <= 1 ? nil : comps.dropLast().joined(separator: "/")
    }
    /// フッター表示用のフォルダ名（ルートは「ルート」）
    private var currentFolderLabel: String {
        let source = displayPath ?? noteId
        let comps = source.components(separatedBy: "/")
        return comps.count <= 1 ? "ルート" : comps.dropLast().joined(separator: "/")
    }

    // MARK: - ナビタイトル

    var navTitle: String {
        let source = displayPath ?? noteId
        return source.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "") ?? source
    }

    // MARK: - ノートメニュー（右上 ⋯）

    /// このノートがピン留め中か（フロントマターの pin: N を見る）。
    private var isPinned: Bool {
        let lines = extraFrontmatter.isEmpty ? [] : extraFrontmatter.components(separatedBy: "\n")
        return FrontmatterParser.extractPin(from: lines) != nil
    }

    /// 外部アプリからこのノートを開く URL スキームリンク。
    /// path はフルパス（.md 抜き）。クエリ値に使えない文字はエンコードする。
    private var urlSchemeLink: String {
        let p = displayPath ?? noteId
        let trimmed = p.hasSuffix(".md") ? String(p.dropLast(3)) : p
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return "couchnotes://open?path=\(encoded)"
    }

    private var noteMenu: some View {
        Menu {
            Button {
                Task { await togglePin() }
            } label: {
                if isPinned {
                    Label("ピン留めを外す", systemImage: "pin.slash")
                } else {
                    Label("ピン留め", systemImage: "pin")
                }
            }
            Divider()
            Button {
                UIPasteboard.general.string = "[[\(navTitle)]]"
            } label: {
                Label("ノートリンクをコピー", systemImage: "link")
            }
            Button {
                UIPasteboard.general.string = urlSchemeLink
            } label: {
                Label("URLスキームをコピー", systemImage: "arrow.up.forward.app")
            }
            Button {
                UIPasteboard.general.string = editingContent
            } label: {
                Label("本文をコピー", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("削除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// ピン留めをトグルする。未保存の編集があれば先にローカルへ永続化してから
    /// PinService（ストアの本文を読んで extra だけ差し替える）を呼ぶ。
    /// 完了後、ストアの extra をビューへ読み戻す（次回保存でピンが消えないように）。
    private func togglePin() async {
        if hasUnsavedChanges { await persistLocalDirty() }
        if isPinned {
            await PinService.unpin(noteId)
        } else {
            await PinService.pin(noteId)
        }
        if let stored = await NoteStore.shared.editingNote(noteId) {
            extraFrontmatter = stored.extra ?? ""
        }
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
    }

    /// このノートを削除して一覧へ戻る。一覧の長押し削除と同じ
    /// 「pendingDelete → SyncEngine が押し上げ」経路（オフラインでも操作可）。
    private func deleteThisNote() async {
        // 進行中・予約済みの保存を止める（削除後に dirty 保存が走ると復活してしまう）
        isDeletedNote = true
        saveDebounceTask?.cancel()
        localSaveDebounceTask?.cancel()
        hasUnsavedChanges = false
        await NoteStore.shared.markPendingDelete(noteId)
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        onGoToList?()
        await SyncEngine.shared.flush()
    }

    // MARK: - タイトル欄（本文上に固定表示）

    /// 本文の1行目として表示するタイトル欄。Enter または フォーカスが外れた時に確定（リネーム）。
    private var titleField: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                TextField("タイトル", text: $titleDraft, axis: .vertical)
                    .font(.system(size: CGFloat(fontSize) + 1, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onChange(of: titleDraft) { _, newVal in
                        // 変換確定後の「本当のEnter」だけが改行を生む。改行を確定の合図として扱う。
                        if newVal.contains("\n") {
                            titleDraft = newVal.replacingOccurrences(of: "\n", with: "")
                            titleFocused = false   // フォーカスを外す → 下の onChange で確定
                        }
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { Task { await commitTitle() } }
                    }

                // 保存ステータスは固定サイズの枠で確保し、出ても枠が伸縮しないようにする
                Color.clear
                    .frame(width: 22, height: 22)
                    .overlay { saveStatusView }
            }
            .frame(minHeight: 30)   // 1行タイトルでも一定の高さを確保（伸縮防止）
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // タイトルと本文の境界（うっすら）
            Divider()
                .padding(.horizontal, 12)
                .opacity(0.5)
        }
    }

    // MARK: - 検索（詳細画面）

    var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("ノートを検索", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { commitSearch() }
                .onChange(of: searchText) { _, q in runSearch(q) }
            if !searchText.isEmpty {
                Button { searchText = ""; titleResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// 入力中のタイトル候補ドロップダウン（タップでそのノートを開く）。
    var titleDropdown: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(titleResults) { note in
                    Button { openFromSearch(note) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(note.shortTitle)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                }
            }
        }
        .frame(maxHeight: 280)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator).opacity(0.5))
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private func toggleSearch() {
        if showSearch {
            showSearch = false
            searchText = ""
            titleResults = []
            searchFocused = false
        } else {
            showSearch = true
        }
    }

    /// 入力中：タイトル候補を 200ms デバウンスで更新。
    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let r = await NoteStore.shared.searchTitles(trimmed)
            guard !Task.isCancelled else { return }
            titleResults = r
        }
    }

    /// Enter：その語で一覧の本文検索を開く（一覧へ戻る）。
    private func commitSearch() {
        let trimmed = trimmedSearch
        guard !trimmed.isEmpty else { return }
        searchFocused = false
        showSearch = false
        onSearchCommit?(trimmed)
    }

    /// タイトル候補タップ：そのノートを開き、検索枠を閉じる。
    private func openFromSearch(_ item: NoteItem) {
        showSearch = false
        searchText = ""
        titleResults = []
        searchFocused = false
        onLinkTap?(item.id)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("読み込み中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 外部更新バナー
                if externalChangeAvailable {
                    ExternalChangeBanner(
                        onAccept: {
                            withAnimation {
                                content                 = pendingExternalContent
                                editingContent          = pendingExternalContent
                                hasUnsavedChanges       = false
                                externalChangeAvailable = false
                                pendingExternalContent  = ""
                                saveStatus              = .idle
                                saveDebounceTask?.cancel()
                            }
                        },
                        onIgnore: {
                            withAnimation {
                                externalChangeAvailable = false
                                pendingExternalContent  = ""
                            }
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.horizontal, landscapeSideInset)
                }

                if showSearch {
                    searchBar.padding(.horizontal, landscapeSideInset)
                }

                titleField
                    .padding(.horizontal, landscapeSideInset)

                // テキストビューは全幅のまま（スクロールバーが画面端に出る）。
                // 余白は textContainerInset（テキストの内側）で寄せる。
                Group {
                    if useCodeMirror {
                        CodeMirrorWebEditor(
                            text: $editingContent,
                            wikiTargets: wikiTargetNames,
                            mentionedTargets: mentionedTargets,
                            fontSize: CGFloat(fontSize),
                            lineSpacing: CGFloat(lineSpacing),
                            horizontalInset: landscapeSideInset,
                            fontCSSURL: webFontCSSURL,
                            fontFamily: webFontFamily,
                            livePreview: livePreview,
                            backlinks: backlinks,
                            twoHop: twoHop,
                            footerLayout: backlinksLayout,
                            bridge: webBridge,
                            onLinkTap: onLinkTap,
                            onFooterLayoutChange: { backlinksLayout = $0 }
                        )
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if webBridge.isEditorFocused { webEditorToolbar }
                        }
                    } else {
                        MarkdownTextView(
                            text: $editingContent,
                            notes: notes,
                            backlinks: backlinks,
                            fontSize: CGFloat(fontSize),
                            lineSpacing: CGFloat(lineSpacing),
                            horizontalInset: landscapeSideInset,
                            onLinkTap: onLinkTap
                        )
                    }
                }
                    .onChange(of: editingContent) { _, newVal in
                        hasUnsavedChanges = newVal != content

                        guard hasUnsavedChanges else { return }

                        // ローカルへの dirty 永続化は短い間隔で先行させる（ネットワークは絡めない）。
                        // これにより、サーバ push を待たずに「入力はディスクに乗っている」状態を早く作る。
                        localSaveDebounceTask?.cancel()
                        localSaveDebounceTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled, hasUnsavedChanges else { return }
                            await persistLocalDirty()
                        }

                        saveDebounceTask?.cancel()
                        saveDebounceTask = Task {
                            do {
                                try await Task.sleep(for: .seconds(2))
                            } catch {
                                return
                            }
                            guard !Task.isCancelled,
                                  hasUnsavedChanges,
                                  !externalChangeAvailable
                            else { return }
                            // 保存はデバウンス Task のキャンセル対象から切り離す。
                            // こうしないと、次の入力で saveDebounceTask をキャンセルした際に
                            // 進行中の保存（HTTP リクエスト）まで中断され、URLError.cancelled が
                            // networkError として誤検知され、サーバ側だけ適用される ack ロストを招く。
                            Task { await save() }
                        }
                    }
                    .overlay(alignment: .top) {
                        if showTitleDropdown { titleDropdown }
                    }
                    // 写真ピッカーの提示元は常設のこのビューに置く。ツールバー内に置くと、
                    // ピッカー表示時のエディタ blur で isEditorFocused=false になりツールバー
                    // ごと破棄され、ピッカーが閉じてしまう（特に共有アルバム）。
                    .photosPicker(isPresented: $showPhotoPicker,
                                  selection: $photoPickerItem,
                                  matching: .images)
            }

            // 新エディタでキーボード表示中はフッターを隠す（キーボード上に浮くのを防ぐ）
            if !isLoading, !(useCodeMirror && webBridge.isEditorFocused) {
                EditorFooterBar(
                    folderLabel: currentFolderLabel,
                    createdText: DateDisplay.string(fromMs: createdMs),
                    updatedText: DateDisplay.string(fromMs: updatedMs),
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onFolderTap: { showFolderPicker = true },
                    onGoBack:    { onGoBack?() },
                    onGoForward: { onGoForward?() }
                )
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { editorSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in editorSize = newSize }
            }
        )
        // 旧エディタ: SwiftUI のキーボード回避（フレーム移動）を画面全体で抑止（インセットは自前管理）。
        // 新エディタ: キーボード回避を活かし、safeAreaInset のツールバーをキーボード上に持ち上げる。
        .ignoresSafeArea(.keyboard, edges: useCodeMirror ? [] : .bottom)
        .animation(.easeInOut(duration: 0.25), value: externalChangeAvailable)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onGoToList?() } label: {
                    Image(systemName: (NoteListLayout(rawValue: layoutRaw) ?? .detail).icon)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { toggleSearch() } label: {
                    Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                }
                noteMenu
            }
        }
        .alert("エラー", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // 削除確認。Mac Catalyst では confirmationDialog が popover 表示になり
        // クラッシュの前歴があるため alert を使う。
        .alert("「\(navTitle)」を削除しますか？", isPresented: $showDeleteConfirm) {
            Button("削除", role: .destructive) { Task { await deleteThisNote() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は元に戻せません。")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView(
                folders: SyncScope.normalizedFolders,
                current: currentFolderKey
            ) { folder in
                Task { await moveNote(to: folder) }
            }
        }
        .sheet(isPresented: $showNewNote) {
            NewNoteView(
                folders: SyncScope.normalizedFolders,
                initialFolder: currentFolderKey
            ) { title, folder in
                Task { await createNote(title: title, folder: folder) }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .noteDidChange)
        ) { notification in
            guard
                let changedId = notification.userInfo?["noteId"] as? String,
                changedId == noteId
            else { return }
            Task { await applyExternalChangeIfNeeded() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .noteStoreDidChange)
        ) { _ in
            // 他ノートの更新でこのノートへの被リンクが変わりうるため更新
            Task { await loadBacklinks() }
        }
        .onChange(of: network.isOnline) { _, online in
            // オフライン→オンラインに復帰した時、未保存の変更があれば再試行
            guard online, hasUnsavedChanges, saveStatus == .unsaved,
                  !externalChangeAvailable else { return }
            Task { await save() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in
            // バックグラウンド遷移直前に即ローカル永続化（デバウンス待ちの間にkillされても入力を失わない安全網）。
            guard hasUnsavedChanges else { return }
            Task { await persistLocalDirty() }
        }
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task { await uploadPickedPhoto(item) }
        }
        .task {
            // 最後に開いたノートとして記録
            UserDefaults.standard.set(noteId, forKey: "lastOpenedNoteId")
            // この画面の save() が押し上げを担うので、同期ワーカはこのノートを飛ばす
            SyncEngine.shared.activeNoteId = noteId
            titleDraft = navTitle
            webBridge.onError = { message in errorMessage = message }
            await loadContent()
            await loadBacklinks()
            await pollForChanges()
        }
        .onDisappear {
            saveDebounceTask?.cancel()
            localSaveDebounceTask?.cancel()
            if hasUnsavedChanges {
                Task { await save() }
            }
            if SyncEngine.shared.activeNoteId == noteId {
                SyncEngine.shared.activeNoteId = nil
            }
        }
    }

    // MARK: - 新エディタ（CodeMirror）用

    /// [[ ]] 補完・リンク存在判定に渡すノート名一覧（小文字重複は除去）。
    private var wikiTargetNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for note in notes {
            let title = note.shortTitle
            if seen.insert(title.lowercased()).inserted { out.append(title) }
        }
        return out
    }

    /// キーボード上の自前ツールバー（旧エディタの inputAccessoryView 相当）。
    /// WKWebView は inputAccessoryView を差し替えられないため、safeAreaInset で重ねる。
    /// 見た目は旧 KeyboardToolbarView と同じ「薄い角丸背景の小型ボタンを等分配置」。
    private var webEditorToolbar: some View {
        HStack(spacing: 5) {
            webToolbarButton(systemImage: "clipboard") { webBridge.pasteFromClipboard() }
            webToolbarButton(systemImage: "photo.badge.plus") { showPhotoPicker = true }
            webToolbarButton("[[ ]]") { webBridge.run("wikiLink") }
            webToolbarButton(systemImage: "checklist") { webBridge.run("listToggle") }
            webToolbarButton(systemImage: "arrow.up") { webBridge.run("moveLineUp") }
            webToolbarButton(systemImage: "arrow.down") { webBridge.run("moveLineDown") }
            webToolbarButton(systemImage: "arrow.left.to.line") { webBridge.run("outdent") }
            webToolbarButton(systemImage: "arrow.right.to.line") { webBridge.run("indent") }
            webToolbarButton(systemImage: "keyboard.chevron.compact.down") { webBridge.dismissKeyboard() }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func webToolbarButton(_ title: String? = nil,
                                  systemImage: String? = nil,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            webToolbarLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    /// ツールバーボタンの共通見た目（旧 KeyboardToolbarView の makeButton 相当）。
    @ViewBuilder
    private func webToolbarLabel(_ title: String? = nil, systemImage: String? = nil) -> some View {
        Group {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
            }
        }
        .foregroundStyle(Color(.label))
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color(.quaternarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// 写真ピッカーで選ばれた画像を Gyazo にアップロードして挿入する。
    private func uploadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // PNG マジックバイトで判別（それ以外は JPEG として扱う）
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        webBridge.uploadImage(
            data: data,
            mime: isPNG ? "image/png" : "image/jpeg",
            filename: isPNG ? "image.png" : "image.jpg"
        )
    }

    // MARK: - 保存ステータス表示

    /// 平常時は非表示。サーバへの反映がまだできていない時だけ雲マークで知らせる。
    @ViewBuilder
    var saveStatusView: some View {
        if saveStatus == .unsaved {
            Image(systemName: "icloud.slash")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 外部変更の適用

    private func applyExternalChange(record: NoteRecord) async {
        // 保存進行中に届く変更はほぼ自分のエコー。誤バナーを避けて適用しない（本物は次回ポーリング／409 で拾う）。
        guard !saveInFlight else { return }
        // 自分の保存エコー／_changes に流れる途中世代（rev 世代が基準以下）は無視する。
        // 内容が違って見えても古い自己エコーで、適用すると編集中のカーソルが末尾へ飛ぶ。
        // baseRev 等を stale 値で汚す前に弾く（次回保存の誤 409 も防ぐ）。
        guard isGenuinelyNewer(record.rev) else {
            NSLog("[cursor-diag] applyExternalChange: ignored stale echo rev=\(record.rev ?? "nil") base=\(baseRev ?? "nil")")
            return
        }
        let parsed = FrontmatterParser.split(record.content)
        let fresh  = parsed.body

        // 未保存の編集があるうちは、ローカルの dirty 行に一切触れない。
        // ここで upsert すると sync_state が clean に戻り、まだサーバへ送れていない
        // 自分の編集がディスク上から消えてしまう（メモリ上の editingContent だけが頼りになり、
        // その状態でアプリが終了すると編集が失われる）。バナー表示用に内容だけメモリで保持する。
        guard !hasUnsavedChanges else {
            guard fresh != content else { return }
            pendingExternalContent  = fresh
            externalChangeAvailable = true
            return
        }

        // 未保存の編集が無い場合のみ、サーバ側の内容をローカルへ確定反映する。
        await NoteStore.shared.upsert(record)
        baseRev          = record.rev
        createdMs        = record.ctime
        updatedMs        = record.mtime
        extraFrontmatter = parsed.extraLines.joined(separator: "\n")

        // 入ってきた本文が現在の基準と同一なら外部変更ではない（自分の保存のエコー等）。
        guard fresh != content else { return }
        logExternalReassign(source: "applyExternalChange", fresh: fresh)
        content        = fresh
        editingContent = fresh
    }

    /// [cursor-diag] editingContent を外部値で差し替える直前に、現行値との差分概要を記録する。
    /// 「fresh == content は外れたが内容は実質同じ（末尾改行/改行コードだけ違う）」を炙り出す。
    private func logExternalReassign(source: String, fresh: String) {
        let cur = editingContent
        guard fresh != cur else {
            NSLog("[cursor-diag] \(source): reassign with IDENTICAL editingContent (redundant)")
            return
        }
        let curLen = (cur as NSString).length
        let newLen = (fresh as NSString).length
        let trimmedEqual = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                        == fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        let crlfDiff = cur.contains("\r\n") != fresh.contains("\r\n")
        NSLog("[cursor-diag] \(source): editingContent reassign curLen=\(curLen) newLen=\(newLen) trimmedEqual=\(trimmedEqual) crlfDiff=\(crlfDiff)")
    }

    /// CouchDB の _rev "N-hash" から世代 N を取り出す。形式不正なら nil。
    private func revGeneration(_ rev: String?) -> Int? {
        guard let rev, let dash = rev.firstIndex(of: "-"),
              let gen = Int(rev[rev.startIndex..<dash]) else { return nil }
        return gen
    }

    /// 受信 rev が現在の基準 baseRev より「新しい世代」か。
    /// 基準不明なら true（受け入れ）、受信不明なら false（無視）。
    /// _changes に流れる自分の保存エコーや途中世代（rev 世代が基準以下）を弾くために使う。
    /// 内容差で判定すると、古い世代でも本文が違って見えて適用→カーソルが末尾へ飛ぶため、
    /// 世代の単調性で「本物の外部変更」だけを通す。
    private func isGenuinelyNewer(_ incomingRev: String?) -> Bool {
        guard let inc = revGeneration(incomingRev) else { return false }
        guard let base = revGeneration(baseRev) else { return true }
        return inc > base
    }

    private func applyExternalChangeIfNeeded() async {
        // 保存進行中に届く変更はほぼ自分のエコー。誤バナーを避けて適用しない（本物は次回ポーリング／409 で拾う）。
        guard !saveInFlight else { return }
        // リスナーが既にストアを更新済みなので、そこから最新本文を読む
        guard let stored = await NoteStore.shared.editingNote(noteId) else { return }
        // 自分の保存エコー／途中世代（rev 世代が基準以下）は無視する。詳細は applyExternalChange 参照。
        guard isGenuinelyNewer(stored.rev) else {
            NSLog("[cursor-diag] applyExternalChangeIfNeeded: ignored stale echo rev=\(stored.rev ?? "nil") base=\(baseRev ?? "nil")")
            return
        }
        baseRev          = stored.rev
        createdMs        = stored.ctime
        updatedMs        = stored.mtime
        extraFrontmatter = stored.extra ?? ""
        let fresh = stored.body
        // 入ってきた本文が現在の基準と同一なら外部変更ではない（自分の保存のエコー等）。
        // 未保存中かどうかに関係なく早期 return する（編集中の誤検知バナーを防ぐ）。
        if fresh == content { return }

        if !hasUnsavedChanges {
            logExternalReassign(source: "applyExternalChangeIfNeeded", fresh: fresh)
            content        = fresh
            editingContent = fresh
        } else {
            pendingExternalContent  = fresh
            externalChangeAvailable = true
        }
    }

    // MARK: - ポーリング（15秒ごと）

    private func pollForChanges() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch { break }
            guard !Task.isCancelled else { break }

            guard let record = try? await CouchDBClient.shared.fetchNoteRecord(id: noteId) else { continue }
            let freshBody = FrontmatterParser.split(record.content).body
            guard freshBody != content else { continue }
            await applyExternalChange(record: record)
        }
    }

    // MARK: - ロード

    func loadContent() async {
        if let stored = await NoteStore.shared.editingNote(noteId) {
            content          = stored.body
            editingContent   = stored.body
            baseRev          = stored.rev
            createdMs        = stored.ctime
            updatedMs        = stored.mtime
            extraFrontmatter = stored.extra ?? ""
            isLoading        = false
            await refreshInBackground()
            return
        }

        isLoading = true
        do {
            if let record = try await CouchDBClient.shared.fetchNoteRecord(id: noteId) {
                await NoteStore.shared.upsert(record)
                let parsed       = FrontmatterParser.split(record.content)
                content          = parsed.body
                editingContent   = parsed.body
                baseRev          = record.rev
                createdMs        = record.ctime
                updatedMs        = record.mtime
                extraFrontmatter = parsed.extraLines.joined(separator: "\n")
            } else {
                content        = ""
                editingContent = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadBacklinks() async {
        backlinks = await NoteStore.shared.backlinks(for: noteId)
        // 2ホップ（新エディタのフッター用）。自分と直接バックリンクは重複表示しない。
        let excluding = Set(backlinks.map(\.id) + [noteId])
        twoHop = await NoteStore.shared.twoHopGroups(for: noteId, excludingIDs: excluding)

        // 言及のみの未作成ページ名（サジェスト用）: 全リンク先キーから実在ノートを除く。
        // キーは正規化済み（小文字・.md 除去）なので、実在側も同じ形に揃えて比較する。
        var existingKeys = Set<String>()
        for note in notes {
            var idKey = note.id.lowercased()
            if idKey.hasSuffix(".md") { idKey = String(idKey.dropLast(3)) }
            existingKeys.insert(idKey)
            existingKeys.insert(note.shortTitle.lowercased())
        }
        let allKeys = await NoteStore.shared.allLinkTargetKeys()
        mentionedTargets = allKeys.filter { !existingKeys.contains($0) }
    }

    // MARK: - フォルダ移動

    /// 現在のノートを選んだフォルダ（nil=ルート）へ移動する。
    private func moveNote(to folder: String?) async {
        showFolderPicker = false
        guard folder?.lowercased() != currentFolderKey else { return }

        // 未保存があれば先に保存（保存できなければ移動しない）
        if hasUnsavedChanges {
            await save()
            guard !hasUnsavedChanges else {
                errorMessage = "保存できていないため移動できません。通信状況を確認してください。"
                return
            }
        }

        let filename        = noteId.components(separatedBy: "/").last ?? noteId
        let displayFilename = (displayPath ?? noteId).components(separatedBy: "/").last ?? filename
        // _id はフォルダも小文字、path はフォルダ原文（Obsidian の実フォルダ名）
        let newId   = folder.map { "\($0.lowercased())/\(filename)" } ?? filename
        let newPath = folder.map { "\($0)/\(displayFilename)" }       ?? displayFilename

        do {
            try await CouchDBClient.shared.moveNote(fromId: noteId, toId: newId, newPath: newPath)
            let record = NoteRecord(
                id: newId, path: newPath,
                mtime: Date().timeIntervalSince1970 * 1000,
                ctime: nil, size: content.utf8.count, content: content
            )
            await NoteStore.shared.upsert(record)
            await NoteStore.shared.delete(noteId)
            UserDefaults.standard.set(newId, forKey: "lastOpenedNoteId")
            NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
            onMoved?(newId)
        } catch {
            errorMessage = "移動に失敗しました\n\(error.localizedDescription)"
        }
    }

    /// タイトル欄の確定（リネーム＋他ページのリンク書き換え）→ 新IDへ遷移。
    /// Enter／フォーカスが外れた時に呼ばれる。変化が無い・空・case のみの変更なら元に戻す。
    private func commitTitle() async {
        let newTitle = titleDraft
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newTitle.isEmpty, newTitle != navTitle else {
            titleDraft = navTitle   // 空・変更なしは現タイトルへ戻す
            return
        }
        do {
            let newId = try await RenameService.rename(oldId: noteId, oldPath: displayPath, newTitle: newTitle)
            if newId != noteId { onMoved?(newId) }
        } catch RenameError.unchanged {
            titleDraft = navTitle   // 実質変化なし（大文字小文字のみ等）は静かに戻す
        } catch {
            errorMessage = error.localizedDescription
            titleDraft = navTitle   // 失敗時は現タイトルへ戻す
        }
    }

    /// 選んだフォルダ（nil=ルート）にタイトルで新規ノートを作成して開く。
    private func createNote(title: String, folder: String?) async {
        showNewNote = false
        guard let naming = NoteNaming.make(title: title, folder: folder) else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let sec   = Int(nowMs / 1000)
        let fullText = FrontmatterParser.compose(createdSec: sec, updatedSec: sec, extra: [], body: "")
        // ローカルに dirty で作成（オフラインでも作成可）→ 同期ワーカがサーバへ押し上げる。
        await NoteStore.shared.saveDirty(NoteRecord(
            id: naming.id, path: naming.path,
            mtime: nowMs, ctime: nowMs,
            size: fullText.utf8.count, content: fullText
        ))
        UserDefaults.standard.set(naming.id, forKey: "lastOpenedNoteId")
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        onCreated?(naming.id)
        await SyncEngine.shared.flush()
    }

    private func refreshInBackground() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let record = try await CouchDBClient.shared.fetchNoteRecord(id: noteId) else { return }
            let freshBody = FrontmatterParser.split(record.content).body
            guard freshBody != content else { return }
            await applyExternalChange(record: record)
        } catch { }
    }

    // MARK: - 保存

    /// 現在の editingContent からフロントマター込みの NoteRecord を組み立てる（保存・ローカル永続化の共通処理）。
    /// - Returns: record, 保存対象の本文スナップショット, 現在時刻(ms), 作成時刻(ms)
    private func buildRecordForSave() -> (record: NoteRecord, savedBody: String, nowMs: Double, createdFor: Double) {
        // 実際に保存する本文をスナップショット（保存中にタイプされても基準がズレないように）
        let savedBody  = editingContent
        // フロントマター（created=ctime / updated=now）を付けて全文を組み立てる
        let nowMs      = Date().timeIntervalSince1970 * 1000
        let createdFor = createdMs ?? nowMs
        let createdSec = Int(createdFor / 1000)
        let updatedSec = Int(nowMs / 1000)
        let extraLines = extraFrontmatter.isEmpty ? [] : extraFrontmatter.components(separatedBy: "\n")
        let fullText   = FrontmatterParser.compose(
            createdSec: createdSec, updatedSec: updatedSec, extra: extraLines, body: savedBody
        )
        let record = NoteRecord(
            id: noteId, path: displayPath ?? noteId,
            mtime: nowMs, ctime: createdFor, size: fullText.utf8.count, content: fullText
        )
        return (record, savedBody, nowMs, createdFor)
    }

    /// ローカルへの dirty 永続化のみ行う（ネットワーク送信はしない）。
    /// 入力停止直後の短いデバウンスとバックグラウンド遷移時に呼ばれ、
    /// サーバ push を待たずに「入力はディスクに乗っている」状態を素早く作る安全網。
    private func persistLocalDirty() async {
        guard !isDeletedNote else { return }
        let (record, _, _, _) = buildRecordForSave()
        await NoteStore.shared.saveDirty(record)
    }

    func save() async {
        // 削除済みノートには保存しない（dirty 保存が走ると削除したはずのノートが復活する）
        guard !isDeletedNote else { return }
        // 保存を直列化：既に保存中なら保留にして即 return。完了後に最新内容で1回だけ再保存する。
        // （保存を重ねると baseRev が古いまま 2 本目が走り、自分の保存を 409＝外部更新と誤検知してしまう）
        if saveInFlight {
            pendingSave = true
            return
        }
        saveInFlight = true
        defer {
            saveInFlight = false
            if pendingSave {
                pendingSave = false
                if hasUnsavedChanges { Task { await save() } }
            }
        }

        let (record, savedBody, nowMs, createdFor) = buildRecordForSave()

        // 1) まずローカルに dirty として永続化（オフライン・kill されても編集が残る）。
        //    基準(content)はまだ動かさない＝push 成功まで「未保存」のまま retry 対象にする。
        await NoteStore.shared.saveDirty(record)

        // 2) オフラインなら push せず終了。dirty のまま、復帰時に再試行／同期ワーカが押し上げる。
        guard NetworkMonitor.shared.isOnline else {
            saveStatus = .unsaved
            return
        }

        // 3) サーバへ push（楽観ロック：基準 rev とずれていれば 409 で競合検知）
        do {
            let newRev = try await CouchDBClient.shared.saveNoteContentChecked(
                id: noteId, path: displayPath ?? noteId, text: record.content, ctime: createdFor, baseRev: baseRev)
            await markSaved(savedBody: savedBody, nowMs: nowMs, newRev: newRev)
        } catch CouchDBError.networkError {
            // ネットワークエラー: アラートを出さず、未保存(dirty)を保持して再接続を待つ
            saveStatus = .unsaved
        } catch CouchDBError.httpError(409, _) {
            // 競合。サーバ側が削除済みか、他端末の編集かで分岐。
            if let record = try? await CouchDBClient.shared.fetchNoteRecord(id: noteId) {
                // 編集 vs 編集 → サーバ最新を取り込み、ExternalChangeBanner で解決をユーザに委ねる
                await applyExternalChange(record: record)
                saveStatus = .unsaved
            } else if let tomb = try? await CouchDBClient.shared.currentLeafRev(id: noteId),
                      let newRev = try? await CouchDBClient.shared.saveNoteContentChecked(
                          id: noteId, path: displayPath ?? noteId, text: record.content, ctime: createdFor, baseRev: tomb) {
                // 削除 vs 編集 → 墓標の上に編集を復元（データ保全）し、ユーザに通知
                await markSaved(savedBody: savedBody, nowMs: nowMs, newRev: newRev)
                errorMessage = "このノートは他の端末で削除されていましたが、あなたの編集で復元しました。"
            } else {
                saveStatus = .unsaved
            }
        } catch {
            // ネットワーク以外のエラー（認証失敗・5xx・デコードエラー等）はアラート
            errorMessage = "保存に失敗しました\n\(error.localizedDescription)"
            saveStatus   = .unsaved
        }
    }

    /// push 成功後の共通後処理（基準の更新・clean 化）。平常時は表示を出さないので即 .idle に戻す。
    private func markSaved(savedBody: String, nowMs: Double, newRev: String) async {
        if createdMs == nil { createdMs = nowMs }
        updatedMs = nowMs
        // 基準（content/baseRev）は await の「前」に更新する。
        // markClean でストアが clean になった後に content が古いままだと、その隙間に自分の
        // 保存エコーが届いたとき「外部更新」と誤検知してバナーが出るため。
        baseRev                 = newRev
        content                 = savedBody
        hasUnsavedChanges       = editingContent != savedBody
        externalChangeAvailable = false
        pendingExternalContent  = ""
        saveStatus              = .idle
        await NoteStore.shared.markClean(noteId, rev: newRev)
        NotificationCenter.default.post(name: .noteSaved, object: nil, userInfo: ["noteId": noteId])
    }
}

// MARK: - 外部更新バナー

struct ExternalChangeBanner: View {
    let onAccept: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("別デバイスで更新がありました")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("外部の変更を取り込む", action: onAccept)
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("このまま編集", action: onIgnore)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .overlay(Divider(), alignment: .bottom)
    }
}

// MARK: - エディタ下部フッター

struct EditorFooterBar: View {
    let folderLabel: String
    let createdText: String
    let updatedText: String
    let canGoBack: Bool
    let canGoForward: Bool
    let onFolderTap: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    private var dateLine: String {
        var parts: [String] = []
        if !createdText.isEmpty { parts.append("作成 \(createdText)") }
        if !updatedText.isEmpty { parts.append("更新 \(updatedText)") }
        return parts.joined(separator: "  ・  ")
    }

    var body: some View {
        VStack(spacing: 4) {
            if !dateLine.isEmpty {
                Text(dateLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            HStack(spacing: 0) {
                // 左：戻る / 進む
                Button(action: onGoBack) {
                    Image(systemName: "chevron.backward").font(.body)
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)
                .foregroundStyle(canGoBack ? Color.accentColor : Color.secondary.opacity(0.4))

                Button(action: onGoForward) {
                    Image(systemName: "chevron.forward").font(.body)
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
                .foregroundStyle(canGoForward ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(.leading, 20)

                Spacer()

                // 右：フォルダ選択
                Button(action: onFolderTap) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(folderLabel).lineLimit(1)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - 新規ノート作成

struct NewNoteView: View {
    let folders: [String]          // 正規化済み同期フォルダ
    let initialFolder: String?     // 初期選択フォルダ（ルートは nil）
    let onCreate: (_ title: String, _ folder: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var folder: String?

    init(folders: [String], initialFolder: String?, initialTitle: String = "",
         onCreate: @escaping (_ title: String, _ folder: String?) -> Void) {
        self.folders = folders
        self.initialFolder = initialFolder
        self.onCreate = onCreate
        _title  = State(initialValue: initialTitle)
        _folder = State(initialValue: initialFolder)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("ノートのタイトル", text: $title)
                        .autocorrectionDisabled()
                }
                Section("フォルダ") {
                    Picker("フォルダ", selection: $folder) {
                        Text("ルート").tag(Optional<String>.none)
                        ForEach(folders, id: \.self) { f in
                            Text(f).tag(Optional(f))
                        }
                    }
                }
            }
            .navigationTitle("新規ノート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") { onCreate(title, folder) }
                        .disabled(!canCreate)
                }
            }
        }
    }
}

// MARK: - フォルダ選択

struct FolderPickerView: View {
    let folders: [String]        // 正規化済み同期フォルダ
    let current: String?         // 現在のフォルダ（ルートは nil）
    let onSelect: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(label: "ルート", systemImage: "house", isSelected: current == nil) {
                    onSelect(nil)
                }
                ForEach(folders, id: \.self) { folder in
                    row(label: folder, systemImage: "folder", isSelected: current == folder.lowercased()) {
                        onSelect(folder)
                    }
                }
            }
            .navigationTitle("フォルダを選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func row(label: String, systemImage: String,
                     isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
