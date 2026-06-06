import SwiftUI
import Combine
import Network

extension Notification.Name {
    /// ローカル編集の保存が成功した時に投げる通知。userInfo["noteId"] に対象 ID。
    static let noteSaved = Notification.Name("couchNotes.noteSaved")
}

enum SaveStatus: Equatable {
    case idle
    case editing
    case saving
    case saved
    case unsaved    // ネットワーク断などで保存できていない状態（次回オンライン時に再試行）
    case error
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

    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0

    @ObservedObject private var network = NetworkMonitor.shared

    @State private var content        = ""
    @State private var editingContent = ""
    @State private var isLoading      = true
    @State private var isRefreshing   = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var hasUnsavedChanges     = false

    // 外部更新バナー用
    @State private var externalChangeAvailable = false
    @State private var pendingExternalContent  = ""

    // デバウンス保存用
    @State private var saveDebounceTask: Task<Void, Never>?

    // バックリンク（本文末尾に表示）
    @State private var backlinks: [NoteItem] = []

    // フォルダ移動
    @State private var showFolderPicker = false

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
                }

                MarkdownTextView(
                    text: $editingContent,
                    notes: notes,
                    backlinks: backlinks,
                    fontSize: CGFloat(fontSize),
                    lineSpacing: CGFloat(lineSpacing),
                    onLinkTap: onLinkTap
                )
                    .onChange(of: editingContent) { _, newVal in
                        hasUnsavedChanges = newVal != content

                        guard hasUnsavedChanges else { return }

                        // 既に未保存状態なら .editing に戻さず、未保存表示を維持する
                        if saveStatus != .unsaved {
                            saveStatus = .editing
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
                            await save()
                        }
                    }
            }

            if !isLoading {
                EditorFooterBar(folderLabel: currentFolderLabel) {
                    showFolderPicker = true
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)   // SwiftUI のキーボード回避（フレーム移動）を画面全体で抑止
        .animation(.easeInOut(duration: 0.25), value: externalChangeAvailable)
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onGoToList?() } label: {
                    Image(systemName: "rectangle.stack")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { onGoBack?() } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!canGoBack)

                Button { onGoForward?() } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!canGoForward)

                saveStatusView

                if isRefreshing {
                    ProgressView().scaleEffect(0.7)
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
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView(
                folders: SyncScope.normalizedFolders,
                current: currentFolderKey
            ) { folder in
                Task { await moveNote(to: folder) }
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
        .task {
            // 最後に開いたノートとして記録
            UserDefaults.standard.set(noteId, forKey: "lastOpenedNoteId")
            await loadContent()
            await loadBacklinks()
            await pollForChanges()
        }
        .onDisappear {
            saveDebounceTask?.cancel()
            if hasUnsavedChanges {
                Task { await save() }
            }
        }
    }

    // MARK: - 保存ステータス表示

    @ViewBuilder
    var saveStatusView: some View {
        switch saveStatus {
        case .idle:
            EmptyView()
        case .editing:
            Text("編集中")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saving:
            ProgressView().scaleEffect(0.8)
        case .saved:
            Label("保存済み", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.green)
        case .unsaved:
            Label("未保存", systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error:
            Label("保存失敗", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - 外部変更の適用

    private func applyExternalChange(record: NoteRecord) async {
        await NoteStore.shared.upsert(record)
        let fresh = record.content

        if !hasUnsavedChanges {
            content        = fresh
            editingContent = fresh
        } else {
            pendingExternalContent  = fresh
            externalChangeAvailable = true
        }
    }

    private func applyExternalChangeIfNeeded() async {
        // リスナーが既にストアを更新済みなので、そこから最新本文を読む
        guard let fresh = await NoteStore.shared.content(noteId) else { return }
        if fresh == content && !hasUnsavedChanges { return }

        if !hasUnsavedChanges {
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
            let cached = await NoteStore.shared.content(noteId) ?? ""
            guard record.content != cached else { continue }
            await applyExternalChange(record: record)
        }
    }

    // MARK: - ロード

    func loadContent() async {
        if let cached = await NoteStore.shared.content(noteId) {
            content        = cached
            editingContent = cached
            isLoading      = false
            await refreshInBackground()
            return
        }

        isLoading = true
        do {
            if let record = try await CouchDBClient.shared.fetchNoteRecord(id: noteId) {
                await NoteStore.shared.upsert(record)
                content        = record.content
                editingContent = record.content
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
    }

    // MARK: - フォルダ移動

    /// 現在のノートを選んだフォルダ（nil=ルート）へ移動する。
    private func moveNote(to folder: String?) async {
        showFolderPicker = false
        guard folder != currentFolderKey else { return }

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
        let newId   = folder.map { "\($0)/\(filename)" }        ?? filename
        let newPath = folder.map { "\($0)/\(displayFilename)" } ?? displayFilename

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

    private func refreshInBackground() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let record = try await CouchDBClient.shared.fetchNoteRecord(id: noteId) else { return }
            guard record.content != (await NoteStore.shared.content(noteId) ?? "") else { return }
            await applyExternalChange(record: record)
        } catch { }
    }

    // MARK: - 保存

    func save() async {
        // 既にオフラインと分かっているなら通信を試みず即 unsaved
        guard NetworkMonitor.shared.isOnline else {
            saveStatus = .unsaved
            return
        }

        saveStatus = .saving
        do {
            try await CouchDBClient.shared.saveNoteContent(id: noteId, text: editingContent)
            let record = NoteRecord(
                id: noteId,
                path: displayPath ?? noteId,
                mtime: Date().timeIntervalSince1970 * 1000,
                ctime: nil,
                size: editingContent.utf8.count,
                content: editingContent
            )
            await NoteStore.shared.upsert(record)
            content                 = editingContent
            hasUnsavedChanges       = false
            externalChangeAvailable = false
            pendingExternalContent  = ""
            saveStatus              = .saved
            NotificationCenter.default.post(name: .noteSaved, object: nil,
                                            userInfo: ["noteId": noteId])
            try? await Task.sleep(for: .seconds(2))
            if saveStatus == .saved { saveStatus = .idle }
        } catch CouchDBError.networkError {
            // ネットワークエラー: アラートを出さず、未保存状態を保持して再接続を待つ
            saveStatus = .unsaved
        } catch CouchDBError.httpError(409, _) {
            // 競合（_rev mismatch）: サーバの最新内容を取得し ExternalChangeBanner で解決をユーザに委ねる
            if let record = try? await CouchDBClient.shared.fetchNoteRecord(id: noteId) {
                await applyExternalChange(record: record)
            }
            saveStatus = .unsaved
        } catch {
            // ネットワーク以外のエラー（認証失敗・5xx・デコードエラー等）はアラート
            errorMessage = "保存に失敗しました\n\(error.localizedDescription)"
            saveStatus   = .unsaved
        }
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
    let onFolderTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onFolderTap) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(folderLabel).lineLimit(1)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
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
                    row(label: folder, systemImage: "folder", isSelected: current == folder) {
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
