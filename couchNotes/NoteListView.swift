import SwiftUI

struct NoteListView: View {
    @ObservedObject private var listener = ChangesListener.shared
    @ObservedObject private var urlRouter = URLActionRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("noteList_layout") private var layoutRaw = NoteListLayout.detail.rawValue
    private var layout: NoteListLayout { NoteListLayout(rawValue: layoutRaw) ?? .detail }

    // フォルダ絞り込み："" = すべて／"/" = ルート直下のみ／それ以外 = フォルダ名（配下を表示）
    @AppStorage("noteList_folderFilter") private var folderFilter = ""

    @State private var notes: [NoteItem] = []
    @State private var path: [String]    = []
    @State private var errorMessage: String? = nil
    @State private var showSettings      = false
    @State private var hasLoadedOnce     = false   // 初回ロード完了後の再ロードを制御
    @State private var noteToDelete: NoteItem? = nil   // 長押し削除の確認対象
    @State private var noteToRename: NoteItem? = nil   // タイトル変更の対象
    @State private var renameText  = ""

    // 検索
    @State private var searchText    = ""
    @State private var searchResults: [NoteItem] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var showNewNote   = false
    @FocusState private var searchFocused: Bool

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一覧に表示するノート（検索中は検索結果、そうでなければ全件）。さらにフォルダ絞り込みを適用。
    private var displayedNotes: [NoteItem] {
        let base = trimmedSearch.isEmpty ? notes : searchResults
        switch folderFilter {
        case "":  return base
        case "/": return base.filter { !$0.id.lowercased().contains("/") }   // ルート直下のみ
        default:
            let prefix = folderFilter.lowercased() + "/"
            return base.filter { $0.id.lowercased().hasPrefix(prefix) }       // 配下（サブフォルダ含む）
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

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isImporting {
                    importView
                } else if notes.isEmpty {
                    emptyView
                } else {
                  VStack(spacing: 0) {
                    searchBar
                    countLabel
                    noteContent
                  }
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
                        path.append(resolved)
                    },
                    onGoBack: {
                        guard path.count > 1, let current = path.last else { return }
                        isClosureNavigation = true
                        historyForward.append(current)
                        path.removeLast()
                    },
                    onGoForward: {
                        guard let next = historyForward.popLast() else { return }
                        isClosureNavigation = true
                        path.append(next)
                    },
                    onGoToList: {
                        isClosureNavigation = true
                        path = []
                    },
                    onMoved: { newId in
                        // 移動後：ナビゲーション先を新IDへ差し替え、一覧も更新
                        isClosureNavigation = true
                        if path.isEmpty { path = [newId] }
                        else { path[path.count - 1] = newId }
                        historyForward = []
                        Task { await loadNotes() }
                    },
                    onCreated: { newId in
                        // 新規作成：そのノートを開く（履歴に積む）
                        isClosureNavigation = true
                        historyForward = []
                        path.append(newId)
                        Task { await loadNotes() }
                    }
                )
            }
            .onChange(of: path) { oldPath, newPath in
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Button {
                            let next = layout.next
                            layoutRaw = next.rawValue
                            saveLayout(next, for: folderFilter)
                        } label: {
                            Image(systemName: layout.icon)
                        }
                        statusIndicator
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    folderFilterMenu
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
            .onChange(of: searchText) { _, query in
                runSearch(query)
            }
            .onChange(of: folderFilter) { _, newFolder in
                // フォルダを切り替えたら、そのフォルダに保存された表示形式へ
                layoutRaw = savedLayout(for: newFolder).rawValue
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
        .task {
            // 現在のフォルダに保存された表示形式を反映
            layoutRaw = savedLayout(for: folderFilter).rawValue
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
                path = [lastId]
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
                    path.append(id)
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

    /// フォルダ絞り込みメニュー（すべて／ルート／同期フォルダ）。選択中は塗りつぶしアイコン。
    var folderFilterMenu: some View {
        Menu {
            Picker("フォルダで絞り込み", selection: $folderFilter) {
                Text("すべて").tag("")
                Text("ルート").tag("/")
                ForEach(SyncScope.normalizedFolders, id: \.self) { folder in
                    Text(folder).tag(folder)
                }
            }
        } label: {
            Image(systemName: folderFilter.isEmpty ? "folder" : "folder.fill")
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
    }

    // MARK: - データ取得

    /// 一覧を SQLite から読み込む（高速・通信なし）
    private func loadNotes() async {
        notes = await NoteStore.shared.listItems()
    }

    /// 検索（200ms デバウンス）。タイトル一致の有無も判定して「＋」表示を制御。
    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await NoteStore.shared.search(trimmed)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    /// 検索語をタイトルに新規ノートを作成して開く（「＋」→ フォルダ選択経由）。
    private func createNoteFromSearch(title: String, folder: String?) async {
        showNewNote = false
        guard let naming = NoteNaming.make(title: title, folder: folder) else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let sec   = Int(nowMs / 1000)
        let fullText = FrontmatterParser.compose(createdSec: sec, updatedSec: sec, extra: [], body: "")
        do {
            try await CouchDBClient.shared.createNote(id: naming.id, path: naming.path, text: fullText)
            await NoteStore.shared.upsert(NoteRecord(
                id: naming.id, path: naming.path,
                mtime: nowMs, ctime: nowMs,
                size: fullText.utf8.count, content: fullText
            ))
            UserDefaults.standard.set(naming.id, forKey: "lastOpenedNoteId")
            await loadNotes()
            searchText = ""
            isClosureNavigation = true
            historyForward = []
            path.append(naming.id)
        } catch {
            errorMessage = "作成に失敗しました\n\(error.localizedDescription)"
        }
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
            NavigationLink(value: note.id) {
                row(note)
            }
            .contextMenu { contextMenuButtons(for: note) }
        }
        .listStyle(.plain)
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay { searchEmptyOverlay }
        .refreshable { await refresh() }
    }

    /// カード表示（iPhone：2列グリッド）。
    private var notesGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(displayedNotes) { note in
                    NavigationLink(value: note.id) {
                        NoteCardView(note: note)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenuButtons(for: note) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .overlay { searchEmptyOverlay }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private func contextMenuButtons(for note: NoteItem) -> some View {
        Button {
            renameText = note.shortTitle
            noteToRename = note
        } label: {
            Label("タイトル変更", systemImage: "pencil")
        }
        Button(role: .destructive) {
            noteToDelete = note
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var searchEmptyOverlay: some View {
        if displayedNotes.isEmpty && !trimmedSearch.isEmpty {
            ContentUnavailableView(
                "一致するノートがありません",
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

    var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("ノートを検索", text: $searchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = false   // キーボードも閉じる
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
                showNewNote = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canCreateFromSearch ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .disabled(!canCreateFromSearch)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.15), value: canCreateFromSearch)
    }

    /// タイトル変更（本体リネーム＋他ページのリンク書き換え）
    private func renameNote(_ note: NoteItem, to title: String) async {
        do {
            let newId = try await RenameService.rename(oldId: note.id, oldPath: note.path, newTitle: title)
            // 万一そのノートを開いていたら遷移先も差し替え
            if let idx = path.firstIndex(of: note.id) {
                isClosureNavigation = true
                path[idx] = newId
            }
            await loadNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
        noteToRename = nil
    }

    /// ノートを削除（サーバ削除 → ローカルストア → 一覧の順で反映）
    private func deleteNote(_ note: NoteItem) async {
        do {
            try await CouchDBClient.shared.deleteNote(id: note.id)
            await NoteStore.shared.delete(note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = error.localizedDescription
        }
        noteToDelete = nil
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
    @State private var imageURL: URL? = nil

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
                    if let imageURL {
                        // Color.clear に画像を overlay することで、画像の本来サイズが
                        // 領域の高さを膨らませない（残り領域にフィットさせ、はみ出しはクリップ）。
                        Color.clear
                            .overlay {
                                AsyncImage(url: imageURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    case .failure:
                                        Color(.systemGray5)
                                    default:
                                        Color(.systemGray6)
                                    }
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
            if let urlString = await NoteStore.shared.firstImageURL(forID: note.id),
               let url = URL(string: urlString) {
                imageURL = url
            } else {
                imageURL = nil
            }
        }
    }
}
