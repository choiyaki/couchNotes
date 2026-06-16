import SwiftUI
import UIKit

// MARK: - 設定トップ（項目リスト）

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ConnectionSettingsView()
                    } label: {
                        Label("接続（CouchDB）", systemImage: "externaldrive.connected.to.line.below")
                    }
                    NavigationLink {
                        SyncFolderSettingsView()
                    } label: {
                        Label("同期フォルダ", systemImage: "folder")
                    }
                    NavigationLink {
                        EditorSettingsView()
                    } label: {
                        Label("エディタ", systemImage: "textformat")
                    }
                    NavigationLink {
                        ImageUploadSettingsView()
                    } label: {
                        Label("画像アップロード（Gyazo）", systemImage: "photo")
                    }
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        Label("GitHub バックアップ", systemImage: "arrow.up.circle")
                    }
                    NavigationLink {
                        MarkdownImportView()
                    } label: {
                        Label("md ファイルを取り込む", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink {
                        MaintenanceSettingsView()
                    } label: {
                        Label("メンテナンス", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        URLSchemeHelpView()
                    } label: {
                        Label("URL スキーム", systemImage: "link")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 接続（CouchDB 接続先＋認証）

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host     = ""
    @State private var dbName   = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saved    = false

    var body: some View {
        Form {
            Section(header: Text("CouchDB 接続先")) {
                TextField("ホスト (例: https://example.com:5984)", text: $host)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("データベース名", text: $dbName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section(header: Text("認証情報")) {
                TextField("ユーザー名", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("パスワード", text: $password)
            }
        }
        .navigationTitle("接続")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
        .onAppear(perform: load)
        .overlay {
            if saved {
                VStack {
                    Spacer()
                    Text("✓ 保存しました")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: saved)
    }

    private func load() {
        let km = KeychainManager.shared
        host     = km.load(key: "couchdb_host")     ?? ""
        dbName   = km.load(key: "couchdb_db")       ?? ""
        username = km.load(key: "couchdb_user")     ?? ""
        password = km.load(key: "couchdb_password") ?? ""
    }

    private func save() {
        let km = KeychainManager.shared
        km.save(key: "couchdb_host",     value: host)
        km.save(key: "couchdb_db",       value: dbName)
        km.save(key: "couchdb_user",     value: username)
        km.save(key: "couchdb_password", value: password)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            saved = false
            dismiss()
        }
    }
}

// MARK: - 同期フォルダ

struct SyncFolderSettingsView: View {
    @State private var syncFolders: [String] = []
    @State private var newFolder = ""

    var body: some View {
        Form {
            Section(
                footer: Text("ルート直下のノートは常に同期されます。指定したフォルダ配下も同期対象になります。追加すると不足分を取得し、削除するとローカルから除外します。フォルダ名は大文字・小文字を区別します（Obsidian のフォルダ名に合わせてください）。")
            ) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("ルート")
                    Spacer()
                    Text("常に同期").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(syncFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder)
                    }
                }
                .onDelete(perform: deleteFolders)
                HStack {
                    TextField("フォルダ名を追加", text: $newFolder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(addFolder)
                    Button("追加", action: addFolder)
                        .disabled(SyncScope.normalize(newFolder).isEmpty)
                }
            }
        }
        .navigationTitle("同期フォルダ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncFolders = SyncScope.normalizedFolders }
    }

    private func addFolder() {
        guard let added = SyncScope.add(newFolder) else { return }
        syncFolders = SyncScope.normalizedFolders
        newFolder = ""
        NotificationCenter.default.post(
            name: .syncScopeDidChange, object: nil,
            userInfo: ["added": [added], "removed": [String]()]
        )
    }

    private func deleteFolders(at offsets: IndexSet) {
        let removed = offsets.map { syncFolders[$0] }
        for folder in removed { SyncScope.remove(folder) }
        syncFolders = SyncScope.normalizedFolders
        NotificationCenter.default.post(
            name: .syncScopeDidChange, object: nil,
            userInfo: ["added": [String](), "removed": removed]
        )
    }
}

// MARK: - エディタ

struct EditorSettingsView: View {
    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("文字サイズ: \(Int(fontSize))pt").font(.subheadline)
                    Slider(value: $fontSize, in: 12...24, step: 1)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("行間: \(lineSpacing, specifier: "%.1f")pt").font(.subheadline)
                    Slider(value: $lineSpacing, in: 0...12, step: 0.5)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("エディタ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 画像アップロード（Gyazo）

struct ImageUploadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section(
                header: Text("Gyazo アクセストークン"),
                footer: Text("キーボードの写真ボタンから画像を Gyazo にアップロードして挿入します。トークンは https://gyazo.com/oauth/applications で取得できます。")
            ) {
                SecureField("アクセストークン", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle("画像アップロード")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
        .onAppear(perform: load)
        .overlay {
            if saved {
                VStack {
                    Spacer()
                    Text("✓ 保存しました")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: saved)
    }

    private func load() {
        token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
    }

    private func save() {
        KeychainManager.shared.save(key: GyazoUploadService.tokenKey,
                                    value: token.trimmingCharacters(in: .whitespacesAndNewlines))
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            saved = false
            dismiss()
        }
    }
}

// MARK: - メンテナンス（created/updated 付与）

struct MaintenanceSettingsView: View {
    @State private var migrating       = false
    @State private var migrateProgress = 0.0
    @State private var migrationDone   = false

    // 削除済みの物理削除（purge）
    @State private var purging       = false
    @State private var purgeProgress = 0.0
    @State private var purgeConfirm  = false
    @State private var purgeResult: String?

    var body: some View {
        Form {
            Section(
                header: Text("created / updated"),
                footer: Text("全ノートの YAML に created/updated を付与します。既に YAML がある場合はそちらを正として ctime/mtime に反映します。1回だけ実行してください。")
            ) {
                if migrating {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: migrateProgress)
                        Text("付与中… \(Int(migrateProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        runMigration()
                    } label: {
                        Label(
                            migrationDone ? "created/updated を付与（実行済み）" : "created/updated を全ノートに付与",
                            systemImage: migrationDone ? "checkmark.circle" : "calendar.badge.plus"
                        )
                    }
                }
            }

            Section(
                header: Text("削除済みの整理"),
                footer: Text("削除済みノートと、不要になったチャンクを CouchDB から物理削除（_purge）します。全端末が削除を同期し終えたタイミングで実行してください（未同期の端末があると復活する場合があります）。元に戻せません。")
            ) {
                if purging {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: purgeProgress)
                        Text("削除中… \(Int(purgeProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(role: .destructive) {
                        purgeConfirm = true
                    } label: {
                        Label("削除済みを完全削除（チャンク整理）", systemImage: "trash.slash")
                    }
                }
            }
        }
        .navigationTitle("メンテナンス")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { migrationDone = await FrontmatterMigration.isDone() } }
        .alert("完全削除", isPresented: $purgeConfirm) {
            Button("削除", role: .destructive) { runPurge() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除済みノートと不要チャンクを物理削除します。全端末が同期済みであることを確認してください。元に戻せません。")
        }
        .alert("完全削除", isPresented: Binding(
            get: { purgeResult != nil },
            set: { if !$0 { purgeResult = nil } }
        )) {
            Button("OK") { purgeResult = nil }
        } message: {
            Text(purgeResult ?? "")
        }
    }

    private func runPurge() {
        purging = true
        purgeProgress = 0
        Task {
            do {
                let r = try await CouchDBClient.shared.purgeDeletedNotes { p in
                    Task { @MainActor in purgeProgress = p }
                }
                purgeResult = "完全削除しました（ノート \(r.notes) 件・チャンク \(r.chunks) 件）"
            } catch {
                purgeResult = "失敗しました\n\(error.localizedDescription)"
            }
            purging = false
        }
    }

    private func runMigration() {
        migrating = true
        migrateProgress = 0
        Task {
            do {
                try await FrontmatterMigration.run { p in
                    Task { @MainActor in migrateProgress = p }
                }
                migrationDone = true
            } catch {
                // 失敗時はそのまま（再実行可能）
            }
            migrating = false
        }
    }
}

// MARK: - URL スキームの解説

struct URLSchemeHelpView: View {
    @State private var copied = false

    var body: some View {
        Form {
            Section(footer: Text("他アプリ・iOS ショートカット・Web リンクから couchnotes:// で開けます。content / text は URL エンコードが必要です（ショートカットの「URL を開く」推奨）。")) {
                LabeledContent("スキーム", value: "couchnotes://")
            }

            action(
                title: "open（開く）",
                desc: "既存ノートを開きます。見つからなければエラー表示。",
                url: "couchnotes://open?path=Publish/会議メモ"
            )
            action(
                title: "new（新規作成）",
                desc: "無ければ作成、あれば開いて content を末尾に追記。常に開きます。",
                url: "couchnotes://new?path=Inbox/買い物&content=牛乳"
            )
            action(
                title: "append（追記）",
                desc: "常に作成 or 追記。改行を入れて text を末尾に追記（newline=false で改行なし）。常に開きます。",
                url: "couchnotes://append?path=20260608&text=思いついたこと"
            )

            Section(
                header: Text("path の指定"),
                footer: Text("スラッシュありはフォルダ内、なしはルート直下。.md は省略可。フォルダ名・ファイル名は元の大文字小文字で。")
            ) {
                LabeledContent("フォルダ内", value: "Publish/会議メモ")
                LabeledContent("ルート直下", value: "会議メモ")
            }
        }
        .navigationTitle("URL スキーム")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if copied {
                VStack {
                    Spacer()
                    Text("✓ コピーしました")
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.green).foregroundStyle(.white)
                        .clipShape(Capsule()).padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: copied)
    }

    @ViewBuilder
    private func action(title: String, desc: String, url: String) -> some View {
        Section(header: Text(title)) {
            Text(desc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(url)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = url
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
        }
    }
}
