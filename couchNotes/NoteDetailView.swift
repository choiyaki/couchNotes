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
    var onCreated:    ((String) -> Void)? = nil   // 新規作成したノートを開くため親へ通知

    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0

    @ObservedObject private var network = NetworkMonitor.shared

    @State private var content        = ""
    @State private var editingContent = ""
    @State private var isLoading      = true

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

    // デバウンス保存用
    @State private var saveDebounceTask: Task<Void, Never>?

    // バックリンク（本文末尾に表示）
    @State private var backlinks: [NoteItem] = []

    // フォルダ移動・新規作成
    @State private var showFolderPicker = false
    @State private var showNewNote      = false

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
                EditorFooterBar(
                    folderLabel: currentFolderLabel,
                    createdText: DateDisplay.string(fromMs: createdMs),
                    updatedText: DateDisplay.string(fromMs: updatedMs),
                    onFolderTap: { showFolderPicker = true },
                    onNewTap:    { showNewNote = true }
                )
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
        let parsed = FrontmatterParser.split(record.content)
        createdMs        = record.ctime
        updatedMs        = record.mtime
        extraFrontmatter = parsed.extraLines.joined(separator: "\n")
        let fresh = parsed.body

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
        guard let stored = await NoteStore.shared.editingNote(noteId) else { return }
        createdMs        = stored.ctime
        updatedMs        = stored.mtime
        extraFrontmatter = stored.extra ?? ""
        let fresh = stored.body
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

    /// 選んだフォルダ（nil=ルート）にタイトルで新規ノートを作成して開く。
    private func createNote(title: String, folder: String?) async {
        showNewNote = false
        guard let naming = NoteNaming.make(title: title, folder: folder) else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let sec   = Int(nowMs / 1000)
        let fullText = FrontmatterParser.compose(createdSec: sec, updatedSec: sec, extra: [], body: "")
        do {
            try await CouchDBClient.shared.createNote(id: naming.id, path: naming.path, text: fullText)
            let record = NoteRecord(
                id: naming.id, path: naming.path,
                mtime: nowMs, ctime: nowMs,
                size: fullText.utf8.count, content: fullText
            )
            await NoteStore.shared.upsert(record)
            UserDefaults.standard.set(naming.id, forKey: "lastOpenedNoteId")
            NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
            onCreated?(naming.id)
        } catch {
            errorMessage = "作成に失敗しました\n\(error.localizedDescription)"
        }
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

    func save() async {
        // 既にオフラインと分かっているなら通信を試みず即 unsaved
        guard NetworkMonitor.shared.isOnline else {
            saveStatus = .unsaved
            return
        }

        saveStatus = .saving
        // フロントマター（created=ctime / updated=now）を付けて全文を保存
        let nowMs      = Date().timeIntervalSince1970 * 1000
        let createdSec = Int((createdMs ?? nowMs) / 1000)
        let updatedSec = Int(nowMs / 1000)
        let extraLines = extraFrontmatter.isEmpty ? [] : extraFrontmatter.components(separatedBy: "\n")
        let fullText   = FrontmatterParser.compose(
            createdSec: createdSec, updatedSec: updatedSec, extra: extraLines, body: editingContent
        )
        do {
            try await CouchDBClient.shared.saveNoteContent(id: noteId, text: fullText)
            if createdMs == nil { createdMs = nowMs }
            updatedMs = nowMs
            let record = NoteRecord(
                id: noteId,
                path: displayPath ?? noteId,
                mtime: nowMs,
                ctime: createdMs,
                size: fullText.utf8.count,
                content: fullText
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
    let createdText: String
    let updatedText: String
    let onFolderTap: () -> Void
    let onNewTap: () -> Void

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

                Button(action: onNewTap) {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
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
