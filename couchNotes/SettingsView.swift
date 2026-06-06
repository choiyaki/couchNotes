import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host     = ""
    @State private var dbName   = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saved    = false

    @AppStorage("editor_fontSize")    private var fontSize:    Double = 16
    @AppStorage("editor_lineSpacing") private var lineSpacing: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("エディター")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文字サイズ: \(Int(fontSize))pt")
                            .font(.subheadline)
                        Slider(value: $fontSize, in: 12...24, step: 1)
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("行間: \(lineSpacing, specifier: "%.1f")pt")
                            .font(.subheadline)
                        Slider(value: $lineSpacing, in: 0...12, step: 0.5)
                    }
                    .padding(.vertical, 4)
                }
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
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            saved = false
            dismiss()
        }
    }
}
