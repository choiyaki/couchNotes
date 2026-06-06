import SwiftUI

struct NoteListView: View {
    @ObservedObject private var listener = ChangesListener.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var notes: [NoteItem] = []
    @State private var path: [String]    = []
    @State private var isLoading         = false
    @State private var isPrefetching     = false
    @State private var errorMessage: String? = nil
    @State private var showSettings      = false
    @State private var hasLoadedOnce     = false   // 初回ロード完了後の再 fetch を制御
    @State private var cacheGeneration   = 0       // プリフェッチでキャッシュが増えた時に行プレビューを再描画させる

    // 前進履歴（path 自体が後退履歴を兼ねる）
    @State private var historyForward:     [String] = []
    @State private var isClosureNavigation = false   // クロージャ起因の path 変化を swipe と区別

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && notes.isEmpty {
                    ProgressView("読み込み中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if notes.isEmpty {
                    emptyView
                } else {
                    List(notes) { note in
                        NavigationLink(value: note.id) {
                            NoteRowView(note: note, cacheGeneration: cacheGeneration)
                        }
                    }
                    .refreshable {
                        await loadNotes()
                        await prefetchRecentNotes()
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
                    Image(systemName: "rectangle.stack")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    statusIndicator
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
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            // 初回起動時のみ: 前回開いていたノートを復元 + プリフェッチ
            if let lastId = UserDefaults.standard.string(forKey: "lastOpenedNoteId"),
               !lastId.isEmpty {
                path = [lastId]
            }
            await loadNotes()
            await prefetchRecentNotes()
            hasLoadedOnce = true
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
            // 詳細画面で保存が完了したタイミングで再 fetch（onAppear と save のレース対策）
            guard hasLoadedOnce else { return }
            Task { await loadNotes() }
        }
    }

    // MARK: - ステータスインジケーター

    @ViewBuilder
    var statusIndicator: some View {
        HStack(spacing: 5) {
            if isLoading {
                ProgressView().scaleEffect(0.8)
            } else if isPrefetching {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Circle()
                .fill(listener.isConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
        }
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
                    await loadNotes()
                    await prefetchRecentNotes()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - データ取得

    private func loadNotes() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await CouchDBClient.shared.fetchAllNoteIDs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - プリフェッチ

    private func prefetchRecentNotes() async {
        let targets = notes.prefix(15).filter { !NoteCache.shared.has($0.id) }
        guard !targets.isEmpty else { return }

        isPrefetching = true
        defer { isPrefetching = false }

        for note in targets {
            guard !Task.isCancelled else { break }
            if let content = try? await CouchDBClient.shared.fetchNoteContent(id: note.id) {
                NoteCache.shared.set(note.id, content: content)
            }
        }

        // キャッシュが増えたので行プレビューを再評価させる
        cacheGeneration += 1
    }
}

// MARK: - ノート行

struct NoteRowView: View {
    let note: NoteItem
    /// プリフェッチでキャッシュが更新された際に SwiftUI へ再描画を促すためのトークン。
    /// 値自体は使わないが、これが変わることで行ビューの body が再評価される。
    var cacheGeneration: Int = 0

    /// キャッシュ済みの本文から先頭部分をプレビュー用に取り出す（未キャッシュなら nil）。
    /// キャッシュ参照のみなので追加の通信は発生しない。
    private var preview: String? {
        guard let content = NoteCache.shared.get(note.id) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }

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

                if let preview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.6))
                        .lineLimit(3)
                        .padding(.top, 1)
                }
            }

            Spacer()

            if NoteCache.shared.has(note.id) {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
