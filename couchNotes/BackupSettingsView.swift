//
//  BackupSettingsView.swift
//  couchNotes
//
//  GitHub バックアップの設定画面。フォルダ→リポジトリのバックアップ先を複数登録し、
//  一覧の各行から「今すぐバックアップ」を実行する（行タップで設定を編集）。
//

import SwiftUI

struct BackupSettingsView: View {
    @State private var targets: [BackupTarget] = []
    @State private var runningTargetId: UUID? = nil
    @State private var isRestoring = false
    @State private var progress = 0.0
    @State private var resultMessage: String?
    @State private var historyTarget: BackupTarget? = nil

    var body: some View {
        List {
            Section(footer: Text("各行の上向きボタンでバックアップ。行をタップすると設定を編集できます。選んだフォルダの中身を、フォルダ名を外してリポジトリ直下に push します（一方向・上書き）。")) {
                ForEach(targets) { target in
                    row(for: target)
                }
            }
        }
        .navigationTitle("GitHub バックアップ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BackupTargetEditor(target: BackupTarget()) { reload() }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .alert("バックアップ", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .sheet(item: $historyTarget) { target in
            NavigationStack {
                BackupHistoryView(target: target) { sha in
                    historyTarget = nil
                    Task { await restore(target, ref: sha) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for target: BackupTarget) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(target)).font(.headline)
                Text("\(target.folder ?? "全体") → \(target.owner)/\(target.repo)")
                    .font(.caption).foregroundStyle(.secondary)
                if runningTargetId == target.id {
                    Text("\(isRestoring ? "復元中" : "バックアップ中")… \(Int(progress * 100))%")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if let last = target.lastBackup {
                    Text("最終: \(DateDisplay.ymdhm.string(from: last))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if runningTargetId == target.id {
                ProgressView()
            } else {
                Button {
                    historyTarget = target
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.title2)
                }
                .buttonStyle(.borderless)
                .tint(.blue)
                .disabled(runningTargetId != nil)
                Button {
                    Task { await backup(target) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(runningTargetId != nil)
            }
            Image(systemName: "chevron.forward")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .background(
            NavigationLink("") {
                BackupTargetEditor(target: target) { reload() }
            }
            .opacity(0)
        )
    }

    private func reload() { targets = BackupStore.targets }

    private func displayName(_ t: BackupTarget) -> String {
        t.name.isEmpty ? (t.repo.isEmpty ? "（未設定）" : t.repo) : t.name
    }

    private func backup(_ target: BackupTarget) async {
        guard let token = BackupStore.token(for: target.id), !token.isEmpty,
              !target.owner.trimmingCharacters(in: .whitespaces).isEmpty,
              !target.repo.trimmingCharacters(in: .whitespaces).isEmpty else {
            resultMessage = "オーナー・リポジトリ・トークンを設定してください。"
            return
        }
        runningTargetId = target.id
        progress = 0
        let branch = target.branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : target.branch
        let files = await NoteStore.shared.notesForBackup(folder: target.folder)
        do {
            let client = GitHubBackupClient(owner: target.owner, repo: target.repo, branch: branch, token: token)
            let changed = try await client.backup(files: files) { p in
                Task { @MainActor in progress = p }
            }
            var updated = target
            updated.lastBackup = Date()
            BackupStore.upsert(updated)
            reload()
            resultMessage = changed == 0
                ? "変更はありませんでした"
                : "バックアップ完了（\(changed) 件を更新）"
        } catch {
            resultMessage = error.localizedDescription
        }
        runningTargetId = nil
    }

    /// リポジトリの .md を取得し、CouchDB へ一括書き戻す（上書き＋追記）。
    /// `ref` に commit SHA を渡すとその時点の状態へ復元する（タイムマシン）。nil なら最新。
    private func restore(_ target: BackupTarget, ref: String? = nil) async {
        guard let token = BackupStore.token(for: target.id), !token.isEmpty,
              !target.owner.trimmingCharacters(in: .whitespaces).isEmpty,
              !target.repo.trimmingCharacters(in: .whitespaces).isEmpty else {
            resultMessage = "オーナー・リポジトリ・トークンを設定してください。"
            return
        }
        runningTargetId = target.id
        isRestoring = true
        progress = 0
        let branch = target.branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : target.branch
        do {
            let client = GitHubBackupClient(owner: target.owner, repo: target.repo, branch: branch, token: token)
            // 取得（0...0.5）→ 書き戻し（0.5...1）の2フェーズで進捗表示
            let files = try await client.filesForRestore(ref: ref) { p in
                Task { @MainActor in progress = p * 0.5 }
            }
            if files.isEmpty {
                resultMessage = "リポジトリに復元できるノートがありません。"
            } else {
                let written = try await CouchDBClient.shared.restore(files: files) { p in
                    Task { @MainActor in progress = 0.5 + p * 0.5 }
                }
                // ローカル（SQLite）へも即時反映
                let records = files.map { f -> NoteRecord in
                    let parsed = FrontmatterParser.split(f.content)
                    return NoteRecord(
                        id: f.path.lowercased(),
                        path: f.path,
                        mtime: parsed.updated.map { Double($0) * 1000 },
                        ctime: parsed.created.map { Double($0) * 1000 },
                        size: f.content.utf8.count,
                        content: f.content
                    )
                }
                await NoteStore.shared.upsertMany(records)
                resultMessage = written == 0
                    ? "復元完了（変更なし）"
                    : "復元完了（\(written) 件）"
            }
        } catch {
            resultMessage = error.localizedDescription
        }
        isRestoring = false
        runningTargetId = nil
    }
}

// MARK: - バックアップ先の設定（GitHub 設定のみ）

struct BackupTargetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var target: BackupTarget
    @State private var token: String

    init(target: BackupTarget, onChange: @escaping () -> Void) {
        self.onChange = onChange
        _target = State(initialValue: target)
        _token  = State(initialValue: BackupStore.token(for: target.id) ?? "")
    }

    var body: some View {
        Form {
            Section("名前（任意）") {
                TextField("例: 公開ノート", text: $target.name)
            }
            Section("バックアップするフォルダ") {
                Picker("フォルダ", selection: $target.folder) {
                    Text("全体").tag(Optional<String>.none)
                    ForEach(SyncScope.normalizedFolders, id: \.self) { f in
                        Text(f).tag(Optional(f))
                    }
                }
            }
            Section("リポジトリ") {
                TextField("オーナー（ユーザー/Org）", text: $target.owner)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("リポジトリ名", text: $target.repo)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("ブランチ（既定 main）", text: $target.branch)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            Section(footer: Text("fine-grained PAT（対象リポジトリの Contents: Read and write）。Keychain に保存されます。")) {
                SecureField("Personal Access Token", text: $token)
            }
            Section {
                Button(role: .destructive) {
                    BackupStore.remove(target.id)
                    onChange()
                    dismiss()
                } label: {
                    Label("この設定を削除", systemImage: "trash")
                }
            }
        }
        .navigationTitle("バックアップ先")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(); dismiss() }
            }
        }
        .onDisappear { onChange() }
    }

    private func save() {
        if target.branch.trimmingCharacters(in: .whitespaces).isEmpty { target.branch = "main" }
        BackupStore.upsert(target)
        BackupStore.setToken(token, for: target.id)
        onChange()
    }
}

// MARK: - 復元する時点を選ぶ（タイムマシン）

/// バックアップのコミット履歴を「○月○日 HH:mm の状態」として並べ、選んだ時点へ復元する。
/// 実際の復元（確認・進捗・書き戻し）は親の restore(_:ref:) に委ねる。
struct BackupHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let target: BackupTarget
    let onSelect: (String) -> Void   // 選んだコミットの SHA を親へ

    @State private var commits: [GitHubBackupClient.BackupCommit] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var pendingCommit: GitHubBackupClient.BackupCommit?

    var body: some View {
        Group {
            if loading {
                ProgressView("履歴を取得中…")
            } else if let errorMessage {
                ContentUnavailableView("履歴を取得できません",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else if commits.isEmpty {
                ContentUnavailableView("バックアップ履歴がありません",
                                       systemImage: "clock")
            } else {
                List(commits) { commit in
                    Button {
                        pendingCommit = commit
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateDisplay.ymdhm.string(from: commit.date))
                                .font(.body).foregroundStyle(.primary)
                            Text(relative(commit.date))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("復元する時点")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("閉じる") { dismiss() }
            }
        }
        .task { await load() }
        .confirmationDialog(
            pendingCommit.map { "\(DateDisplay.ymdhm.string(from: $0.date)) の状態に復元しますか？" } ?? "",
            isPresented: Binding(
                get: { pendingCommit != nil },
                set: { if !$0 { pendingCommit = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCommit
        ) { commit in
            Button("この時点に復元", role: .destructive) {
                pendingCommit = nil
                onSelect(commit.sha)
            }
            Button("キャンセル", role: .cancel) { pendingCommit = nil }
        } message: { _ in
            Text("この時点のリポジトリ内容で現在のノートを上書きします（同名は上書き・無いものは追加）。ローカルにしか無いノートは削除されません。")
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        guard let token = BackupStore.token(for: target.id), !token.isEmpty,
              !target.owner.trimmingCharacters(in: .whitespaces).isEmpty,
              !target.repo.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "オーナー・リポジトリ・トークンを設定してください。"
            loading = false
            return
        }
        let branch = target.branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : target.branch
        let client = GitHubBackupClient(owner: target.owner, repo: target.repo, branch: branch, token: token)
        do {
            commits = try await client.listCommits()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
