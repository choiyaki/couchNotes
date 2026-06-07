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
    @State private var progress = 0.0
    @State private var resultMessage: String?

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
    }

    @ViewBuilder
    private func row(for target: BackupTarget) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(target)).font(.headline)
                Text("\(target.folder ?? "全体") → \(target.owner)/\(target.repo)")
                    .font(.caption).foregroundStyle(.secondary)
                if runningTargetId == target.id {
                    Text("バックアップ中… \(Int(progress * 100))%")
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
