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
        .onReceive(
            NotificationCenter.default.publisher(for: .noteDidChange)
        ) { notification in
            guard
                let changedId = notification.userInfo?["noteId"] as? String,
                changedId == noteId
            else { return }
            Task { await applyExternalChangeIfNeeded() }
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
