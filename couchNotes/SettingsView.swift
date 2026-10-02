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
                        RandomNoteSettingsView()
                    } label: {
                        Label("ランダムノート", systemImage: "shuffle")
                    }
                    NavigationLink {
                        EditorSettingsView()
                    } label: {
                        Label("エディタ", systemImage: "textformat")
                    }
                    NavigationLink {
                        ImageUploadSettingsView()
                    } label: {
                        Label("画像アップロード", systemImage: "photo")
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
    /// CouchDB 由来のトップレベルフォルダ（大小保持）
    @State private var serverFolders: [String] = []
    /// 同期オン状態のフォルダ（正規化済み）。UI 即応のためミラー保持。
    @State private var enabled: [String] = []
    @State private var newFolder = ""
    @State private var isLoading = true

    var body: some View {
        Form {
            Section(
                footer: Text("ルート直下のノートは常に同期されます。トグルをオンにしたフォルダ配下も同期対象になります（不足分を取得し、オフでローカルから除外）。新しいフォルダは下の入力欄から作成できます。")
            ) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("ルート")
                    Spacer()
                    Text("常に同期").font(.caption).foregroundStyle(.secondary)
                }

                if isLoading {
                    HStack {
                        ProgressView()
                        Text("フォルダを読み込み中…").foregroundStyle(.secondary)
                    }
                }

                ForEach(mergedFolders, id: \.self) { folder in
                    Toggle(isOn: binding(for: folder)) {
                        Label(folder, systemImage: "folder")
                    }
                }
            }
            Section(footer: Text("フォルダはノートを作成した時点で実際に作られます。ここで作成した名前はフォルダの選択肢に加わり、同期オンになります。")) {
                HStack {
                    TextField("新しいフォルダ名", text: $newFolder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(createFolder)
                    Button("作成", action: createFolder)
                        .disabled(SyncScope.normalize(newFolder).isEmpty)
                }
            }
        }
        .navigationTitle("同期フォルダ")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// サーバー由来 ∪ 同期オンのフォルダを小文字重複排除・ソートしたマージ一覧
    private var mergedFolders: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for f in serverFolders + enabled {
            guard seen.insert(f.lowercased()).inserted else { continue }
            result.append(f)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func isEnabled(_ folder: String) -> Bool {
        enabled.contains { $0.lowercased() == folder.lowercased() }
    }

    private func binding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { isEnabled(folder) },
            set: { on in on ? enable(folder) : disable(folder) }
        )
    }

    private func load() async {
        enabled = SyncScope.normalizedFolders
        defer { isLoading = false }
        if let folders = try? await CouchDBClient.shared.fetchTopLevelFolders() {
            serverFolders = folders
        }
    }

    private func enable(_ folder: String) {
        guard let added = SyncScope.add(folder) else { return }
        enabled = SyncScope.normalizedFolders
        NotificationCenter.default.post(
            name: .syncScopeDidChange, object: nil,
            userInfo: ["added": [added], "removed": [String]()]
        )
    }

    private func disable(_ folder: String) {
        guard SyncScope.remove(folder) else { return }
        enabled = SyncScope.normalizedFolders
        NotificationCenter.default.post(
            name: .syncScopeDidChange, object: nil,
            userInfo: ["added": [String](), "removed": [folder]]
        )
    }

    private func createFolder() {
        let name = newFolder
        newFolder = ""
        enable(name)
    }
}

// MARK: - ランダムノート（今日のノートの除外フォルダ）

struct RandomNoteSettingsView: View {
    @State private var folders: [String] = []
    @State private var excluded: [String] = []
    @State private var isLoading = true

    var body: some View {
        Form {
            Section(
                footer: Text("一覧の先頭に、毎日ランダムで2件のノートを表示します。チェックしたフォルダ配下のノートは抽選から除外されます。")
            ) {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("フォルダを読み込み中…").foregroundStyle(.secondary)
                    }
                }
                ForEach(folders, id: \.self) { folder in
                    Toggle(isOn: binding(for: folder)) {
                        Label(folder, systemImage: "folder")
                    }
                }
                if !isLoading && folders.isEmpty {
                    Text("フォルダがありません").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("ランダムノート")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func binding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { excluded.contains { $0.lowercased() == folder.lowercased() } },
            set: { on in
                if on { RandomNotes.addExcluded(folder) } else { RandomNotes.removeExcluded(folder) }
                excluded = RandomNotes.normalizedExcluded
            }
        )
    }

    private func load() async {
        excluded = RandomNotes.normalizedExcluded
        let items = await NoteStore.shared.listItems()
        var list = RandomNotes.localTopLevelFolders(from: items)
        // 除外中だが現在ローカルに無いフォルダも一覧に出す（外せるように）
        for e in excluded where !list.contains(where: { $0.lowercased() == e.lowercased() }) {
            list.append(e)
        }
        folders = list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        isLoading = false
    }
}

// MARK: - エディタ

struct EditorSettingsView: View {
    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0
    @AppStorage("editor_webFontCSSURL") private var webFontCSSURL = ""
    @AppStorage("editor_webFontFamily") private var webFontFamily = ""
    @AppStorage("editor_livePreview") private var livePreview = true

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

            Section(
                footer: Text("カーソルのある行だけ記法（## や [[ ]] など）を表示し、他の行はプレビュー表示にします（Cosense 風）。")
            ) {
                Toggle("記法を隠す（ライブプレビュー）", isOn: $livePreview)
            }

            Section(
                header: Text("Web フォント"),
                footer: Text("Google Fonts 等の CSS URL とフォント名を指定すると本文に適用されます。例: URL に https://fonts.googleapis.com/css2?family=Noto+Serif+JP&display=swap、フォント名に Noto Serif JP。空欄でシステムフォント。オフライン時は自動でシステムフォントに戻ります。")
            ) {
                TextField("CSS の URL", text: $webFontCSSURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("フォント名（font-family）", text: $webFontFamily)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle("エディタ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 画像アップロード（Gyazo / couchimg）

struct ImageUploadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ImageUploader.backendKey) private var backend = ImageUploader.Backend.gyazo.rawValue
    @State private var token = ""
    @State private var saved = false

    // couchimg の登録
    @State private var pairCode = ""
    @State private var adminCode = ""
    @State private var isWorking = false
    @State private var couchImgMessage: String?
    @State private var registeredName = CouchImgService.deviceName
    @State private var hasAdmin = CouchImgService.hasAdminToken
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section(
                header: Text("アップロード先"),
                footer: Text("写真ボタン・ペースト・手書きメモの画像を上げる先です。問題が出たら Gyazo に戻せます。すでにノートに貼ってある画像は、どちらを選んでも表示されます。")
            ) {
                Picker("アップロード先", selection: $backend) {
                    Text("Gyazo").tag(ImageUploader.Backend.gyazo.rawValue)
                    Text("couchimg（自分のサーバー）").tag(ImageUploader.Backend.couchimg.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section(
                header: Text("couchimg: この端末の登録"),
                footer: Text("8文字の登録コードを入力します（5分・1回だけ有効）。コードは、登録済みの iPhone の「端末の追加と一覧」か、サーバーで couchimg-token pair <端末名> を実行すると出ます。アップロードした画像は、最初はすべて非公開です。")
            ) {
                if let registeredName {
                    LabeledContent("登録済みの端末名", value: registeredName)
                    Button("登録がまだ有効か確かめる") { run { try await CouchImgService.checkRegistration(); return "登録は有効です。" } }
                    Button("この端末の登録を消す", role: .destructive) { confirmForget = true }
                } else {
                    Text("未登録").foregroundStyle(.secondary)
                }
                TextField("登録コード（例: ABCD-EFGH）", text: $pairCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button(registeredName == nil ? "登録する" : "登録し直す") {
                    run {
                        let name = try await CouchImgService.pair(code: pairCode)
                        pairCode = ""
                        registeredName = name
                        return "「\(name)」として登録しました。"
                    }
                }
                .disabled(pairCode.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }

            Section(
                header: Text("couchimg: 管理用の登録（公開・削除）"),
                footer: Text("画像の公開と削除は、WireGuard を繋いでいるときだけ使えます。WireGuard を繋いだ状態で、サーバーで couchimg-token admin-pair <端末名> を実行して出たコードを入力します。")
            ) {
                LabeledContent("管理用の登録", value: hasAdmin ? "済み" : "なし")
                TextField("管理用の登録コード", text: $adminCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button("管理用の登録をする") {
                    run {
                        try await CouchImgService.pairAdmin(code: adminCode)
                        adminCode = ""
                        hasAdmin = true
                        return "管理用の登録をしました。"
                    }
                }
                .disabled(adminCode.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }

            if hasAdmin {
                Section(footer: Text("ほかの端末（PC のブラウザ・iPad・Mac）用の登録コードを出したり、登録済みの端末を無効にしたりします。WireGuard を繋いでいるときだけ使えます。")) {
                    NavigationLink("端末の追加と一覧") { CouchImgDevicesView() }
                }
            }

            Section(
                header: Text("Gyazo アクセストークン"),
                footer: Text("トークンは https://gyazo.com/oauth/applications で取得できます。右上の「保存」で保存します。")
            ) {
                SecureField("アクセストークン", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .alert("couchimg", isPresented: Binding(
            get: { couchImgMessage != nil },
            set: { if !$0 { couchImgMessage = nil } }
        )) {
            Button("OK") { couchImgMessage = nil }
        } message: {
            Text(couchImgMessage ?? "")
        }
        .alert("この端末の登録を消しますか？", isPresented: $confirmForget) {
            Button("消す", role: .destructive) {
                CouchImgService.forgetRegistration()
                registeredName = nil
                hasAdmin = false
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この端末に保存したトークンを消します。サーバー側でも無効にするには、サーバーで couchimg-token revoke <端末名> を実行してください。")
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

    /// couchimg への操作を実行し、結果（成功の文言かエラー）を表示する。
    private func run(_ work: @escaping () async throws -> String) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do { couchImgMessage = try await work() } catch { couchImgMessage = error.localizedDescription }
        }
    }

    private func load() {
        let stored = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
        token = GyazoUploadService.normalizedToken(stored)
        if token != stored {
            KeychainManager.shared.save(key: GyazoUploadService.tokenKey, value: token)
        }
    }

    private func save() {
        token = GyazoUploadService.normalizedToken(token)
        KeychainManager.shared.save(key: GyazoUploadService.tokenKey, value: token)
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
                header: Text("空ノートの整理"),
                footer: Text("YAML はあるが本文が空のノートを一覧表示し、選んで削除します。ピン留め中のノートは対象外です。")
            ) {
                NavigationLink {
                    EmptyNotesCleanupView()
                } label: {
                    Label("空ノートを確認", systemImage: "doc.badge.gearshape")
                }
            }
        }
        .navigationTitle("メンテナンス")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { migrationDone = await FrontmatterMigration.isDone() } }
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

// MARK: - 空ノートの整理

struct EmptyNotesCleanupView: View {
    @State private var items: [NoteItem] = []
    @State private var checked: Set<String> = []
    @State private var isLoading  = true
    @State private var isDeleting = false
    @State private var confirmDelete = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("空ノートを検索中…").foregroundStyle(.secondary)
                }
            } else if items.isEmpty {
                Text("本文が空のノートはありません").foregroundStyle(.secondary)
            } else {
                Section(footer: Text("削除したくないものはチェックを外してください。")) {
                    ForEach(items) { note in
                        Toggle(isOn: bindingFor(note.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.shortTitle)
                                Text(note.path ?? note.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("空ノートの整理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isDeleting {
                    ProgressView()
                } else {
                    Button("実行", role: .destructive) { confirmDelete = true }
                        .disabled(checked.isEmpty)
                }
            }
        }
        .task { await load() }
        .alert("空ノートを削除", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { Task { await runDelete() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("チェックした \(checked.count) 件を削除します。元に戻せません。")
        }
        .alert("完了", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func bindingFor(_ id: String) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { on in if on { checked.insert(id) } else { checked.remove(id) } }
        )
    }

    private func load() async {
        items = await NoteStore.shared.emptyBodyItems()
        checked = Set(items.map(\.id))
        isLoading = false
    }

    private func runDelete() async {
        isDeleting = true
        let targets = checked
        for id in targets {
            await NoteStore.shared.markPendingDelete(id)
        }
        await SyncEngine.shared.flush()
        items.removeAll { targets.contains($0.id) }
        checked.subtract(targets)
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        resultMessage = "\(targets.count) 件を削除しました"
        isDeleting = false
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
