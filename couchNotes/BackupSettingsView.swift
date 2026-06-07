//
//  BackupSettingsView.swift
//  couchNotes
//
//  GitHub バックアップの設定画面。フォルダ→リポジトリのバックアップ先を複数登録し、
//  各先で「今すぐバックアップ」を実行する。
//

import SwiftUI

struct BackupSettingsView: View {
    @State private var targets: [BackupTarget] = []

    var body: some View {
        List {
            Section(footer: Text("選んだフォルダの中身を、フォルダ名を外してリポジトリ直下に push します（一方向・上書き）。")) {
                ForEach(targets) { target in
                    NavigationLink {
                        BackupTargetEditor(target: target) { reload() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(target)).font(.headline)
                            Text("\(target.folder ?? "全体") → \(target.owner)/\(target.repo)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let last = target.lastBackup {
                                Text("最終: \(DateDisplay.ymdhm.string(from: last))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
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
    }

    private func reload() { targets = BackupStore.targets }

    private func displayName(_ t: BackupTarget) -> String {
        t.name.isEmpty ? (t.repo.isEmpty ? "（未設定）" : t.repo) : t.name
    }
}

// MARK: - バックアップ先の編集

struct BackupTargetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var target: BackupTarget
    @State private var token: String
    @State private var running = false
    @State private var progress = 0.0
    @State private var resultMessage: String?

    init(target: BackupTarget, onChange: @escaping () -> Void) {
        self.onChange = onChange
        _target = State(initialValue: target)
        _token  = State(initialValue: BackupStore.token(for: target.id) ?? "")
    }

    private var canBackup: Bool {
        !target.owner.trimmingCharacters(in: .whitespaces).isEmpty &&
        !target.repo.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.isEmpty && !running
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
                if running {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text("バックアップ中… \(Int(progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        runBackup()
                    } label: {
                        Label("今すぐバックアップ", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canBackup)
                }
                if let last = target.lastBackup {
                    Text("最終バックアップ: \(DateDisplay.ymdhm.string(from: last))")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .alert("バックアップ", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .onDisappear { onChange() }
    }

    private func save() {
        if target.branch.trimmingCharacters(in: .whitespaces).isEmpty { target.branch = "main" }
        BackupStore.upsert(target)
        BackupStore.setToken(token, for: target.id)
        onChange()
    }

    private func runBackup() {
        save()
        running = true
        progress = 0
        let folder = target.folder
        let owner  = target.owner.trimmingCharacters(in: .whitespaces)
        let repo   = target.repo.trimmingCharacters(in: .whitespaces)
        let branch = target.branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : target.branch
        let tok    = token
        Task {
            let files = await NoteStore.shared.notesForBackup(folder: folder)
            do {
                let client = GitHubBackupClient(owner: owner, repo: repo, branch: branch, token: tok)
                let changed = try await client.backup(files: files) { p in
                    Task { @MainActor in progress = p }
                }
                target.lastBackup = Date()
                BackupStore.upsert(target)
                onChange()
                resultMessage = changed == 0
                    ? "変更はありませんでした"
                    : "バックアップ完了（\(changed) 件を更新）"
            } catch {
                resultMessage = error.localizedDescription
            }
            running = false
        }
    }
}
