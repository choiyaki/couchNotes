import SwiftUI

struct NoteListView: View {
    @ObservedObject private var listener = ChangesListener.shared
    @ObservedObject private var urlRouter = URLActionRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("noteList_layout") private var layoutRaw = NoteListLayout.detail.rawValue
    private var layout: NoteListLayout { NoteListLayout(rawValue: layoutRaw) ?? .detail }

    // フォルダ絞り込み（複数選択）：改行区切りで選択キーを保存する。
    // 空 = すべて／"/" = ルート直下／それ以外 = フォルダ名（配下）。複数選択は OR で表示。
    @AppStorage("noteList_folderFilter") private var folderFilter = ""

    /// 選択中のフォルダキー集合（空 = すべて表示）。
    private var selectedFolders: Set<String> {
        get { Set(folderFilter.split(separator: "\n").map(String.init)) }
        nonmutating set { folderFilter = newValue.sorted().joined(separator: "\n") }
    }

    /// レイアウト保存キー。単一選択時はそのフォルダ、それ以外（なし／複数）は「すべて」("")。
    private var layoutKey: String {
        let sel = selectedFolders
        return sel.count == 1 ? sel.first! : ""
    }

    @State private var notes: [NoteItem] = []
    @State private var path: [String]    = []
    @State private var errorMessage: String? = nil
    @State private var showSettings      = false
    @State private var hasLoadedOnce     = false   // 初回ロード完了後の再ロードを制御
    @State private var noteToDelete: NoteItem? = nil   // 長押し削除の確認対象
    @State private var noteToRename: NoteItem? = nil   // タイトル変更の対象
    @State private var renameText  = ""
    @State private var noteToMove:  NoteItem? = nil    // 単体フォルダ移動の対象
    @State private var showFolderMenu = false          // フォルダ絞り込みポップアップの表示

    // 複数選択モード
    @State private var isSelecting   = false
    @State private var selectedIDs:  Set<String> = []
    @State private var showBulkMove  = false

    // 検索
    @State private var showSearch    = false   // 検索枠の表示（検索ボタンでトグル）
    @State private var searchText    = ""
    @State private var titleResults: [NoteItem] = []   // 入力中：タイトル一致（ドロップダウン）
    @State private var bodyResults:  [NoteItem] = []   // Enter後：本文一致（メイン一覧）
    @State private var searchCommitted = false         // Enter で本文検索を確定したか
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var showNewNote   = false
    @State private var searchFocused = false

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 入力中のタイトル候補ドロップダウンを出すか。
    private var showTitleDropdown: Bool {
        showSearch && !searchCommitted && !trimmedSearch.isEmpty && !titleResults.isEmpty
    }

    /// 一覧に表示するノート。Enter で本文検索を確定したら本文一致、それ以外は全件（フォルダ絞り込み適用）。
    private var displayedNotes: [NoteItem] {
        let base = (searchCommitted && !trimmedSearch.isEmpty) ? bodyResults : notes
        let sel = selectedFolders
        guard !sel.isEmpty else { return base }                               // すべて
        return base.filter { note in
            let lid = note.id.lowercased()
            for key in sel {
                if key == "/" {
                    if !lid.contains("/") { return true }                     // ルート直下
                } else if lid.hasPrefix(key.lowercased() + "/") {
                    return true                                               // 配下（サブフォルダ含む）
                }
            }
            return false
        }
    }

    /// 同じタイトルのノートが無ければ作成可能（「＋」を有効化）。空入力時は不可。
    private var canCreateFromSearch: Bool {
        let q = trimmedSearch.lowercased()
        guard !q.isEmpty else { return false }
        return !notes.contains { $0.shortTitle.lowercased() == q }
    }

    // 初回インポート（全件取得）の進捗
    @State private var isImporting     = false
    @State private var importProgress: Double? = nil

    // 前進履歴（path 自体が後退履歴を兼ねる）
    @State private var historyForward:     [String] = []
    @State private var isClosureNavigation = false   // クロージャ起因の path 変化を swipe と区別

    // 画面遷移アニメーション。true に戻すと標準のスライド演出（横からの迫り出し）が復活する。
    private static let animateNavigation = false

    /// path 書き換えに適用するトランザクション。上記フラグに従ってアニメーションを抑制する。
    private var navTransaction: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = !Self.animateNavigation
        return transaction
    }

    /// プログラムによる path 書き換え（プッシュ／ポップ）を navTransaction 経由で実行する。
    private func navigate(_ mutate: () -> Void) {
        withTransaction(navTransaction) { mutate() }
    }

    var body: some View {
        // バインディング経由の書き換え（NavigationLink タップ・スワイプ戻し）にも同じ抑制を適用。
        NavigationStack(path: $path.transaction(navTransaction)) {
            Group {
                if isImporting {
                    importView
                } else if notes.isEmpty {
                    emptyView
                } else {
                  VStack(spacing: 0) {
                    if showSearch { searchBar }
                    countLabel
                    noteContent
                      .overlay(alignment: .top) {
                          if showTitleDropdown { titleDropdown }
                      }
                    footerBar
                  }
                  // キーボードでフッターを押し上げず、隠れたままにする
                  .ignoresSafeArea(.keyboard, edges: .bottom)
                  .confirmationDialog(
                        "「\(noteToDelete?.shortTitle ?? "")」を削除しますか？",
                        isPresented: Binding(
                            get: { noteToDelete != nil },
                            set: { if !$0 { noteToDelete = nil } }
                        ),
                        titleVisibility: .visible,
                        presenting: noteToDelete
                    ) { note in
                        Button("削除", role: .destructive) {
                            Task { await deleteNote(note) }
                        }
                        Button("キャンセル", role: .cancel) {}
                    } message: { _ in
                        Text("この操作は元に戻せません。")
                    }
                    .alert("タイトル変更", isPresented: Binding(
                        get: { noteToRename != nil },
                        set: { if !$0 { noteToRename = nil } }
                    ), presenting: noteToRename) { note in
                        TextField("タイトル", text: $renameText)
                            .autocorrectionDisabled()
                        Button("変更") { Task { await renameNote(note, to: renameText) } }
                        Button("キャンセル", role: .cancel) {}
                    } message: { _ in
                        Text("他ページのリンクも更新されます。")
                    }
                }
            }
            .overlay(alignment: .topLeading) { folderMenuOverlay }
            .animation(.easeOut(duration: 0.12), value: showFolderMenu)
            .navigationTitle("ノート")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { noteId in
                let displayPath = notes.first { $0.id == noteId }?.path
                NoteDetailView(
                    noteId: noteId,
                    displayPath: displayPath,
                    notes: notes,
                    canGoBack: path.count > 1,
                    canGoForward: !historyForward.isEmpty,
                    onLinkTap: { targetId in
                        let lower = targetId.lowercased()
                        let resolved = notes.first { note in
                            let idLower = note.id.lowercased()
                            return idLower == lower || idLower.hasSuffix("/" + lower)
                        }?.id ?? targetId
                        isClosureNavigation = true
                        historyForward = []
                        navigate { path.append(resolved) }
                    },
                    onGoBack: {
                        guard path.count > 1, let current = path.last else { return }
                        isClosureNavigation = true
                        historyForward.append(current)
                        navigate { path.removeLast() }
                    },
                    onGoForward: {
                        guard let next = historyForward.popLast() else { return }
                        isClosureNavigation = true
                        navigate { path.append(next) }
                    },
                    onGoToList: {
                        isClosureNavigation = true
                        navigate { path = [] }
                    },
                    onMoved: { newId in
                        // 移動後：ナビゲーション先を新IDへ差し替え、一覧も更新
                        isClosureNavigation = true
                        navigate {
                            if path.isEmpty { path = [newId] }
                            else { path[path.count - 1] = newId }
                        }
                        historyForward = []
                        Task { await loadNotes() }
                    },
                    onCreated: { newId in
                        // 新規作成：そのノートを開く（履歴に積む）
                        isClosureNavigation = true
                        historyForward = []
                        navigate { path.append(newId) }
                        Task { await loadNotes() }
                    },
                    onSearchCommit: { text in
                        // 詳細画面で Enter → 一覧へ戻り、その語で本文検索を確定表示
                        isClosureNavigation = true
                        navigate { path = [] }
                        showSearch = true
                        searchText = text   // SearchBar 子ビューが live に追従して語を表示
                        searchCommitted = true
                        Task { bodyResults = await NoteStore.shared.searchBodies(text) }
                    }
                )
            }
            .onChange(of: path) { oldPath, newPath in
                // 一覧（root）を表示中に閉じたら起動時も一覧から始める。
                // ノートを開くと NoteDetailView 側が id を記録するので、ここでは一覧復帰時のクリアだけ担う。
                if newPath.isEmpty {
                    UserDefaults.standard.set("", forKey: "lastOpenedNoteId")
                }
                if isClosureNavigation {
                    isClosureNavigation = false
                } else if oldPath.count > newPath.count {
                    // swipe-back / iOS バックボタン → 戻った分を forward 履歴に積む
                    let popped = Array(oldPath.suffix(oldPath.count - newPath.count))
                    historyForward.append(contentsOf: popped.reversed())
                } else {
                    // 一覧からノートを新規に開いた → 履歴クリア
                    historyForward = []
                }
            }
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") { exitSelection() }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("\(selectedIDs.count)件選択")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("移動") { showBulkMove = true }
                            .disabled(selectedIDs.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        folderFilterMenu
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Button {
                                let next = layout.next
                                layoutRaw = next.rawValue
                                saveLayout(next, for: layoutKey)
                            } label: {
                                Image(systemName: layout.icon)
                            }
                            statusIndicator
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { toggleSearch() } label: {
                            Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                        }
                    }
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
            .onChange(of: folderFilter) { _, _ in
                // 選択を切り替えたら、対応するキーに保存された表示形式へ
                layoutRaw = savedLayout(for: layoutKey).rawValue
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNewNote) {
            NewNoteView(
                folders: SyncScope.normalizedFolders,
                initialFolder: nil,
                initialTitle: trimmedSearch
            ) { title, folder in
                Task { await createNoteFromSearch(title: title, folder: folder) }
            }
        }
        .sheet(item: $noteToMove) { note in
            FolderPickerView(
                folders: SyncScope.normalizedFolders,
                current: folderKey(of: note)
            ) { folder in
                noteToMove = nil
                Task {
                    await move(note, to: folder)
                    await loadNotes()
                }
            }
        }
        .sheet(isPresented: $showBulkMove) {
            FolderPickerView(
                folders: SyncScope.normalizedFolders,
                current: nil
            ) { folder in
                showBulkMove = false
                Task { await moveSelected(to: folder) }
            }
        }
        .task {
            // 現在の選択に保存された表示形式を反映
            layoutRaw = savedLayout(for: layoutKey).rawValue
            // 起動: ストアを開く → 空なら全件インポート → 一覧をロード → リスナー開始
            await NoteStore.shared.bootstrap()
            if await NoteStore.shared.count() == 0 {
                await runInitialImport()
            }
            await loadNotes()

            // 前回開いていたノートを復元（存在する場合のみ）
            if let lastId = UserDefaults.standard.string(forKey: "lastOpenedNoteId"),
               !lastId.isEmpty,
               notes.contains(where: { $0.id == lastId }) {
                navigate { path = [lastId] }
            }

            ChangesListener.shared.start()
            hasLoadedOnce = true
            // 起動時に保留中の URL アクションがあれば処理させる
            URLActionRouter.shared.markReady()
        }
        .onChange(of: urlRouter.noteToOpen) { _, newId in
            guard let id = newId else { return }
            Task {
                await loadNotes()
                if path.last != id {
                    isClosureNavigation = true
                    historyForward = []
                    navigate { path.append(id) }
                }
                urlRouter.noteToOpen = nil
            }
        }
        .onChange(of: urlRouter.errorMessage) { _, msg in
            guard let msg else { return }
            errorMessage = msg
            urlRouter.errorMessage = nil
        }
        .onAppear {
            // 詳細画面から戻ってきた時など、再表示のたびにソート順を更新
            guard hasLoadedOnce else { return }
            Task { await loadNotes() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // バックグラウンドから復帰した時にも更新
            guard newPhase == .active, hasLoadedOnce else { return }
            Task { await loadNotes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteSaved)) { _ in
            // 詳細画面で保存が完了したタイミングで再ロード
            guard hasLoadedOnce else { return }
            Task { await loadNotes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreDidChange)) { _ in
            // _changes でストアが更新されたら一覧を反映
            guard hasLoadedOnce else { return }
            Task { await loadNotes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncScopeDidChange)) { note in
            // 同期フォルダの追加→バックフィル取得 / 削除→ローカル除去
            guard hasLoadedOnce else { return }
            let added   = note.userInfo?["added"]   as? [String] ?? []
            let removed = note.userInfo?["removed"] as? [String] ?? []
            Task { await applyScopeChange(added: added, removed: removed) }
        }
    }

    // MARK: - ステータスインジケーター

    @ViewBuilder
    var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(listener.isConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
        }
    }

    /// フォルダ絞り込みボタン。タップでドロップダウンを開閉（再タップで閉じる）。
    /// 実体のパネルは `folderMenuOverlay`（自前の overlay）で描画する。UIKit の `.popover`
    /// を使うと Mac Catalyst で表示トランジション中にクラッシュするため、SwiftUI だけで完結させる。
    var folderFilterMenu: some View {
        Button { showFolderMenu.toggle() } label: {
            Image(systemName: selectedFolders.isEmpty ? "folder" : "folder.fill")
        }
    }

    /// フォルダ絞り込みドロップダウン。ボタン直下（コンテンツ左上）に浮かせる。
    /// 外側タップで閉じ、フォルダ行は開いたまま複数トグルできる。
    @ViewBuilder
    var folderMenuOverlay: some View {
        if showFolderMenu {
            ZStack(alignment: .topLeading) {
                // 外側タップで閉じる透明バックドロップ
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showFolderMenu = false }
                folderFilterList
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    )
                    .padding(.leading, 8)
                    .padding(.top, 4)
            }
            .transition(.opacity)
        }
    }

    /// ドロップダウンの中身。フォルダは開いたまま複数トグル可。「すべて」は選択解除して閉じる。
    private var folderFilterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedFolders = []
                showFolderMenu = false
            } label: {
                filterRow(title: "すべて", checked: selectedFolders.isEmpty)
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    folderToggleRow("ルート", key: "/")
                    ForEach(SyncScope.normalizedFolders, id: \.self) { folder in
                        folderToggleRow(folder, key: folder)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(minWidth: 220)
        .padding(.vertical, 6)
    }

    /// フォルダ1件分のトグル行。タップしてもポップアップは閉じない。
    @ViewBuilder
    private func folderToggleRow(_ title: String, key: String) -> some View {
        Button {
            var sel = selectedFolders
            if sel.contains(key) { sel.remove(key) } else { sel.insert(key) }
            selectedFolders = sel
        } label: {
            filterRow(title: title, checked: selectedFolders.contains(key))
        }
        .buttonStyle(.plain)
    }

    /// チェックマーク付きの行レイアウト。
    private func filterRow(title: String, checked: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.footnote)
                .opacity(checked ? 1 : 0)
            Text(title)
            Spacer(minLength: 12)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 画面下部のフッター：左＝設定。
    var footerBar: some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            Spacer()
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 検索枠の開閉。開く＝表示＋フォーカス、閉じる＝クリア＋フォーカス解除。
    private func toggleSearch() {
        if showSearch {
            showSearch = false
            searchText = ""
            searchFocused = false
            searchCommitted = false
            titleResults = []
            bodyResults = []
        } else {
            showSearch = true
        }
    }

    // MARK: - 初回インポート表示

    var importView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("ノートを取得中…")
                .font(.headline)
            ProgressView(value: importProgress ?? 0)
                .frame(maxWidth: 220)
            Text("\(Int((importProgress ?? 0) * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("初回のみ全件を取得します")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    var emptyView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("ノートが見つかりません")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("設定を確認してください")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Button("再読み込み") {
                    Task {
                        await runInitialImport()
                        await loadNotes()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footerBar   // 空状態でも設定（接続）に入れるように
        }
    }

    // MARK: - データ取得

    /// 一覧を SQLite から読み込む（高速・通信なし）
    private func loadNotes() async {
        notes = await NoteStore.shared.listItems()
    }

    /// 入力中：タイトル一致の候補（ドロップダウン）を更新する。
    /// デバウンスは入力を抱える `SearchBar` 子ビュー側で行うため、ここでは即時に検索する。
    /// 文字が変わるたびに「入力中モード（未確定）」へ戻す。
    private func runSearch(_ query: String) {
        searchTask?.cancel()
        searchCommitted = false   // 編集したらドロップダウンモードへ戻す
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            titleResults = []
            return
        }
        searchTask = Task {
            let results = await NoteStore.shared.searchTitles(trimmed)
            guard !Task.isCancelled else { return }
            titleResults = results
        }
    }

    /// Enter：本文に語句を含むノートだけをメイン一覧に表示する（確定）。
    private func commitSearch() {
        let trimmed = trimmedSearch
        guard !trimmed.isEmpty else { return }
        searchFocused = false       // キーボードを閉じる
        searchCommitted = true
        Task { bodyResults = await NoteStore.shared.searchBodies(trimmed) }
    }

    /// タイトル候補をタップ → そのノートを直接開く。
    private func openFromSearch(_ item: NoteItem) {
        searchFocused = false
        isClosureNavigation = true
        historyForward = []
        navigate { path.append(item.id) }
    }

    /// 検索語をタイトルに新規ノートを作成して開く（「＋」→ フォルダ選択経由）。
    private func createNoteFromSearch(title: String, folder: String?) async {
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
        await loadNotes()
        searchText = ""
        isClosureNavigation = true
        historyForward = []
        navigate { path.append(naming.id) }
        await SyncEngine.shared.flush()
    }

    // MARK: - 一覧本体（表示モード別）

    /// 選択中の表示モードに応じた一覧本体。
    @ViewBuilder
    var noteContent: some View {
        switch layout {
        case .detail: notesList { NoteRowView(note: $0) }
        case .list:   notesList { NoteRowCompactView(note: $0) }
        case .card:   notesGrid
        }
    }

    /// リスト系（詳細・コンパクト）の共通レイアウト。行の中身だけ差し替える。
    @ViewBuilder
    private func notesList<Row: View>(@ViewBuilder row: @escaping (NoteItem) -> Row) -> some View {
        List(displayedNotes) { note in
            if isSelecting {
                Button { toggleSelection(note) } label: {
                    selectableRow(note) { row(note) }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    navigate { path.append(note.id) }
                } label: {
                    row(note)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenuButtons(for: note) }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay { searchEmptyOverlay }
        .refreshable { await refresh() }
    }

    /// カード表示。iPhone は 2 列、iPad は画面幅から列数を算出してカード幅を iPhone とそろえる。
    private var notesGrid: some View {
        GeometryReader { geo in
            let cfg = Self.gridConfig(width: geo.size.width, height: geo.size.height)
            ScrollView {
                LazyVGrid(columns: cfg.columns, spacing: 12) {
                    ForEach(displayedNotes) { note in
                        if isSelecting {
                            Button { toggleSelection(note) } label: {
                                NoteCardView(note: note)
                                    .overlay(alignment: .topTrailing) {
                                        selectionMark(isSelected: selectedIDs.contains(note.id))
                                            .padding(6)
                                    }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                navigate { path.append(note.id) }
                            } label: {
                                NoteCardView(note: note)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenuButtons(for: note) }
                        }
                    }
                }
                .padding(.horizontal, cfg.hPadding)
                .padding(.top, 4)
            }
            .overlay { searchEmptyOverlay }
            .refreshable { await refresh() }
        }
    }

    /// カードグリッドの列定義と左右余白を画面幅から決める。
    /// - 狭い幅（iPhone 縦）は従来どおり 2 列・余白 16。
    /// - 広い幅（iPad / 横向き）はカード幅を iPhone 相当（≈172pt）にそろえて列数を増やし、
    ///   横向きでは両端に広めの余白を取って画面いっぱいに広がらないようにする。
    private static func gridConfig(width: CGFloat, height: CGFloat) -> (columns: [GridItem], hPadding: CGFloat) {
        let spacing: CGFloat = 12
        guard width >= 600 else {
            return ([GridItem(.flexible(), spacing: spacing),
                     GridItem(.flexible(), spacing: spacing)], 16)
        }
        let isLandscape = width > height
        let sidePadding: CGFloat = isLandscape ? max(width * 0.10, 48) : 24
        let target: CGFloat = 172            // iPhone のカード幅相当
        let usable = width - sidePadding * 2
        let count = max(2, Int((usable + spacing) / (target + spacing)))
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
        return (columns, sidePadding)
    }

    /// 選択モードのリスト行：左に選択マーク、右に本来の行内容。
    @ViewBuilder
    private func selectableRow<Row: View>(_ note: NoteItem,
                                          @ViewBuilder content: () -> Row) -> some View {
        HStack(spacing: 12) {
            selectionMark(isSelected: selectedIDs.contains(note.id))
            content()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// 選択状態を示す丸チェック。
    private func selectionMark(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }

    @ViewBuilder
    private func contextMenuButtons(for note: NoteItem) -> some View {
        Button {
            renameText = note.shortTitle
            noteToRename = note
        } label: {
            Label("タイトル変更", systemImage: "pencil")
        }
        Button {
            noteToMove = note
        } label: {
            Label("フォルダを移動", systemImage: "folder")
        }
        Button {
            enterSelection(with: note)
        } label: {
            Label("複数を選択", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) {
            noteToDelete = note
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var searchEmptyOverlay: some View {
        if searchCommitted && displayedNotes.isEmpty && !trimmedSearch.isEmpty {
            ContentUnavailableView(
                "本文に一致するノートがありません",
                systemImage: "magnifyingglass",
                description: Text("「＋」で『\(trimmedSearch)』を作成できます")
            )
        }
    }

    private func refresh() async {
        ChangesListener.shared.start()
        await loadNotes()
    }

    // MARK: - フォルダごとの表示形式

    private static let layoutByFolderKey = "noteList_layoutByFolder"

    /// 指定フォルダに保存された表示形式（未保存なら詳細表示）。
    private func savedLayout(for folder: String) -> NoteListLayout {
        let map = UserDefaults.standard.dictionary(forKey: Self.layoutByFolderKey) as? [String: String] ?? [:]
        return NoteListLayout(rawValue: map[folder] ?? "") ?? .detail
    }

    /// 指定フォルダの表示形式を保存する。
    private func saveLayout(_ layout: NoteListLayout, for folder: String) {
        var map = UserDefaults.standard.dictionary(forKey: Self.layoutByFolderKey) as? [String: String] ?? [:]
        map[folder] = layout.rawValue
        UserDefaults.standard.set(map, forKey: Self.layoutByFolderKey)
    }

    /// ページ数の表示（検索・フォルダ絞り込み中は「表示数 / 全数」）。
    var countLabel: some View {
        HStack {
            Spacer()
            Text(displayedNotes.count == notes.count
                 ? "\(notes.count) ページ"
                 : "\(displayedNotes.count) / \(notes.count) ページ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// 入力中のタイトル候補ドロップダウン（検索枠の下に重ねて表示。タップで直接開く）。
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

    var searchBar: some View {
        SearchBar(
            text: $searchText,
            focused: $searchFocused,
            canCreate: canCreateFromSearch,
            onQueryChange: { q in
                searchText = q          // 親の派生値（＋ボタン活性・新規ノート初期タイトル）を更新
                runSearch(q)            // タイトル候補ドロップダウンを更新
            },
            onSubmit: { q in
                searchText = q
                commitSearch()          // Enter：本文検索を確定
            },
            onClear: {
                searchText = ""
                titleResults = []
                bodyResults = []
                searchCommitted = false
                searchFocused = false   // キーボードも閉じる
            },
            onCreate: { showNewNote = true }
        )
    }

    /// タイトル変更（本体リネーム＋他ページのリンク書き換え）
    private func renameNote(_ note: NoteItem, to title: String) async {
        do {
            let newId = try await RenameService.rename(oldId: note.id, oldPath: note.path, newTitle: title)
            // 万一そのノートを開いていたら遷移先も差し替え
            if let idx = path.firstIndex(of: note.id) {
                isClosureNavigation = true
                navigate { path[idx] = newId }
            }
            await loadNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
        noteToRename = nil
    }

    /// ノートを削除。まずローカルで削除予定（pendingDelete）にして一覧から隠し、
    /// 同期ワーカがサーバへネイティブ削除を押し上げる（オフラインでも操作可・後で同期）。
    private func deleteNote(_ note: NoteItem) async {
        await NoteStore.shared.markPendingDelete(note.id)
        notes.removeAll { $0.id == note.id }
        noteToDelete = nil
        await SyncEngine.shared.flush()   // オンラインならその場でサーバ反映
    }

    // MARK: - 複数選択 / フォルダ移動

    /// note の現在のフォルダキー（_id ベースの小文字、ルートは nil）。
    private func folderKey(of note: NoteItem) -> String? {
        let comps = note.id.components(separatedBy: "/")
        guard comps.count > 1 else { return nil }
        return comps.dropLast().joined(separator: "/")
    }

    /// 選択モードに入り、長押ししたノートを最初の選択にする。
    private func enterSelection(with note: NoteItem) {
        selectedIDs = [note.id]
        isSelecting = true
    }

    /// 選択モードを抜けて選択をクリア。
    private func exitSelection() {
        isSelecting = false
        selectedIDs = []
    }

    /// 行タップで選択をトグル。
    private func toggleSelection(_ note: NoteItem) {
        if selectedIDs.contains(note.id) {
            selectedIDs.remove(note.id)
        } else {
            selectedIDs.insert(note.id)
        }
    }

    /// 単体ノートを選んだフォルダ（nil=ルート）へ移動する。一覧の再読込は呼び出し側で行う。
    private func move(_ note: NoteItem, to folder: String?) async {
        guard folder?.lowercased() != folderKey(of: note) else { return }

        let filename        = note.id.components(separatedBy: "/").last ?? note.id
        let displayFilename = (note.path ?? note.id).components(separatedBy: "/").last ?? filename
        // _id はフォルダも小文字、path はフォルダ原文（Obsidian の実フォルダ名）
        let newId   = folder.map { "\($0.lowercased())/\(filename)" } ?? filename
        let newPath = folder.map { "\($0)/\(displayFilename)" }       ?? displayFilename

        do {
            try await CouchDBClient.shared.moveNote(fromId: note.id, toId: newId, newPath: newPath)
            // 本文は移動で変えないので、元の content をそのまま新IDへ付け替える。
            let content = await NoteStore.shared.content(note.id) ?? ""
            let stored  = await NoteStore.shared.editingNote(note.id)
            let nowMs   = Date().timeIntervalSince1970 * 1000
            await NoteStore.shared.upsert(NoteRecord(
                id: newId, path: newPath,
                mtime: stored?.mtime ?? nowMs, ctime: stored?.ctime,
                size: content.utf8.count, content: content
            ))
            await NoteStore.shared.delete(note.id)
        } catch {
            errorMessage = "「\(note.shortTitle)」の移動に失敗しました\n\(error.localizedDescription)"
        }
    }

    /// 選択中のノートをすべて選んだフォルダへ移動する。
    private func moveSelected(to folder: String?) async {
        let targets = notes.filter { selectedIDs.contains($0.id) }
        for note in targets {
            await move(note, to: folder)
        }
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        exitSelection()
        await loadNotes()
    }

    /// 同期フォルダ変更の反映：削除フォルダはローカル除去、追加フォルダはバックフィル取得
    private func applyScopeChange(added: [String], removed: [String]) async {
        for folder in removed {
            await NoteStore.shared.removeFolder(folder)
        }
        if !added.isEmpty {
            isImporting    = true
            importProgress = 0
            defer { isImporting = false }
            do {
                // 追加フォルダ配下のみ取得（ルートは既に同期済みなので含めない）
                let records = try await CouchDBClient.shared.fetchScopedNotes(
                    folders: added, includeRoot: false
                ) { frac in
                    Task { @MainActor in importProgress = frac }
                }
                await NoteStore.shared.upsertMany(records)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await loadNotes()
    }

    /// 初回の範囲内取得 → SQLite 保存 → last_seq 記録
    private func runInitialImport() async {
        isImporting    = true
        importProgress = 0
        defer { isImporting = false }
        do {
            // 取得中の変更も拾えるよう、開始前の seq を起点として記録する
            let seq = try await CouchDBClient.shared.currentUpdateSeq()
            let records = try await CouchDBClient.shared.fetchScopedNotes(
                folders: SyncScope.normalizedFolders, includeRoot: true
            ) { frac in
                Task { @MainActor in importProgress = frac }
            }
            await NoteStore.shared.upsertMany(records)
            await NoteStore.shared.setSyncValue("last_seq", seq)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 検索バー（入力を子ビューに隔離）

/// 入力中の文字を自前の `@State`（live）で抱え、親 `NoteListView` を毎打鍵で再描画させない。
/// 親へは「デバウンス後・Enter確定・クリア時」だけ伝える。これで大きな一覧の作り直しが止まる。
private struct SearchBar: View {
    @Binding var text: String                  // 親 searchText（派生値の参照元。確定/デバウンス/クリアで同期）
    @Binding var focused: Bool
    let canCreate: Bool
    let onQueryChange: (String) -> Void        // デバウンス後（タイトル候補の更新）
    let onSubmit: (String) -> Void             // Enter（本文検索の確定）
    let onClear: () -> Void
    let onCreate: () -> Void

    @State private var live = ""               // 入力中の文字はここで完結
    @State private var debounce: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                // SwiftUI TextField は Mac Catalyst で「変換中に再描画されると未確定文字を
                // 再挿入する」不具合があるため、IME をネイティブに扱う UITextField を使う。
                IMESafeTextField(
                    text: $live,
                    focused: $focused,
                    placeholder: "ノートを検索",
                    onCommittedChange: { q in scheduleSuggest(q) },   // 変換確定時のみサジェスト更新
                    onSubmit: { q in
                        debounce?.cancel()
                        onSubmit(q)
                    }
                )
                if !live.isEmpty {
                    Button {
                        debounce?.cancel()
                        live = ""
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                onCreate()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canCreate ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.15), value: canCreate)
        .onChange(of: text) { _, newValue in
            // 親が外部から検索語を変えた（詳細画面からの確定遷移）→ フィールドへ反映（検索は起こさない）
            if newValue != live { live = newValue }
        }
        .onAppear {
            if text != live { live = text }   // 確定遷移などで既に語が入っている場合に表示
            // 検索枠が出た瞬間にフォーカス（マウント直後に確実に当てるため async）
            DispatchQueue.main.async { focused = true }
        }
    }

    /// 変換確定した語で 150ms デバウンスしてタイトル候補を更新する。
    private func scheduleSuggest(_ q: String) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            onQueryChange(q)
        }
    }
}

/// IME（未確定文字）を安全に扱う検索用テキストフィールド。
/// SwiftUI TextField は Mac Catalyst で変換中の再描画により未確定文字を二重挿入するため、
/// UITextField を薄くラップし、①変換中は SwiftUI 側からテキストを書き換えない
/// ②変換が確定（markedTextRange == nil）した時だけ値を親へ伝える、で回避する。
private struct IMESafeTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let onCommittedChange: (String) -> Void
    let onSubmit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.borderStyle = .none
        tf.font = .preferredFont(forTextStyle: .body)
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.smartDashesType = .no
        tf.smartQuotesType = .no
        tf.returnKeyType = .search
        tf.clearButtonMode = .never          // × は SwiftUI 側の自前ボタンで出す
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        // HStack 内で横に伸び、隣のボタンに押し負けないように。縦は本来の高さで固定。
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setContentHuggingPriority(.required, for: .vertical)
        tf.setContentCompressionResistancePriority(.required, for: .vertical)
        // 検索を開いた瞬間にフォーカス（表示直後の updateUIView だけだと Catalyst で
        // タイミングが合わないため、生成時にも確実に当てる）。
        DispatchQueue.main.async { [weak tf] in tf?.becomeFirstResponder() }
        return tf
    }

    /// 縦は UITextField 本来の高さに固定（提案された高さいっぱいに伸びて巨大化するのを防ぐ）。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // 変換中（未確定文字がある）は絶対に text を書き換えない＝IME 破壊を防ぐ肝。
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        // フォーカス制御（更新中の firstResponder 変更を避けるため次のループで）
        DispatchQueue.main.async {
            if focused, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !focused, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: IMESafeTextField
        init(_ parent: IMESafeTextField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) {
            // 変換中（未確定文字あり）は SwiftUI 側を一切触らない＝再描画を起こさない。
            guard tf.markedTextRange == nil else { return }
            let value = tf.text ?? ""
            parent.text = value
            parent.onCommittedChange(value)
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            parent.onSubmit(tf.text ?? "")
            return true
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            if parent.focused { parent.focused = false }
        }
    }
}

// MARK: - 表示モード

enum NoteListLayout: String, CaseIterable {
    case detail   // リスト詳細表示（タイトル＋日付＋本文プレビュー）
    case list     // リスト表示（タイトル＋日付の1行）
    case card     // カード表示（2列グリッド）

    /// トグル順：詳細 → リスト → カード → 詳細 …
    var next: NoteListLayout {
        switch self {
        case .detail: return .list
        case .list:   return .card
        case .card:   return .detail
        }
    }

    /// ツールバーに出す現在モードのアイコン。
    var icon: String {
        switch self {
        case .detail: return "list.bullet.rectangle"
        case .list:   return "list.bullet"
        case .card:   return "square.grid.2x2"
        }
    }
}

// MARK: - ノート行

struct NoteRowView: View {
    let note: NoteItem

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.shortTitle)
                        .font(.headline)
                    if note.isToday {
                        Text("今日")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(note.lastModifiedString)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let preview = note.preview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.6))
                        .lineLimit(3)
                        .padding(.top, 1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ノート行（コンパクト：タイトル＋日付の1行）

struct NoteRowCompactView: View {
    let note: NoteItem

    var body: some View {
        HStack(spacing: 8) {
            Text(note.shortTitle)
                .font(.body)
                .lineLimit(1)
            if note.isToday {
                Text("今日")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 8)
            Text(note.lastModifiedString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ノートカード

struct NoteCardView: View {
    let note: NoteItem
    @State private var imageURL: URL? = nil       // このノートが画像を持つか（レイアウト判断用）
    @State private var uiImage: UIImage? = nil     // 読み込み済みのサムネイル本体

    var body: some View {
        // Color で正方形を確定（横幅基準）し、内容をオーバーレイ。はみ出す画像は上下をクリップ。
        Color(.systemGray6)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(alignment: .leading, spacing: 4) {
                    // タイトル（最大3行）＋日付。fixedSize で圧縮されず常に確保する。
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 5) {
                            Text(note.shortTitle)
                                .font(.footnote.weight(.semibold))
                                .lineSpacing(1)
                                .lineLimit(3)
                            if note.isToday {
                                Text("今日")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(note.lastModifiedString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // タイトル下の残り領域：画像があれば画像、なければ本文プレビュー
                    if imageURL != nil {
                        // Color.clear に画像を overlay することで、画像の本来サイズが
                        // 領域の高さを膨らませない（残り領域にフィットさせ、はみ出しはクリップ）。
                        Color.clear
                            .overlay {
                                if let uiImage {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color(.systemGray6)   // 読み込み中／失敗時の枠
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let preview = note.preview {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(.primary.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: note.id) {
            // 可視カードだけ本文を引いて先頭の画像URL（https）を検出する
            guard let urlString = await NoteStore.shared.firstImageURL(forID: note.id),
                  let url = URL(string: urlString) else {
                imageURL = nil
                uiImage = nil
                return
            }
            imageURL = url
            // キャッシュ済みなら即描画。無ければキャッシュ付きローダで取得（再利用に強い）。
            if let cached = ThumbnailLoader.shared.cached(url) {
                uiImage = cached
                return
            }
            uiImage = nil
            let img = await ThumbnailLoader.shared.image(for: url)
            if !Task.isCancelled { uiImage = img }
        }
    }
}
