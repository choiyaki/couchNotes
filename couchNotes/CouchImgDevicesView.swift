//
//  CouchImgDevicesView.swift
//  couchNotes
//
//  couchimg の「端末を追加」（登録コードの発行）と「登録済みの端末」（一覧・無効化）。
//  設計は ../couchimg/docs/DESIGN.md 4.6。どれも管理用（admin）のトークンで、WireGuard を繋いでいるときだけ使える。
//  ここから出せる・無効にできるのは upload・app だけ。管理用の登録はサーバーのコマンドでだけ増やせる・消せる。
//

import SwiftUI

extension CouchImgService {
    // MARK: - 応答の形

    struct Device: Decodable, Equatable, Identifiable {
        let name: String
        let kinds: [String]         // ここから無効にできる種類（upload・app）
        let staticKinds: [String]   // サーバーのコマンドでだけ無効にできる種類（admin・ocr・index）
        let createdAt: Double?
        let expiresAt: Double?      // nil = ずっと
        let lastUploadAt: Double?
        var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name, kinds, staticKinds = "static_kinds", createdAt = "created_at"
            case expiresAt = "expires_at", lastUploadAt = "last_upload_at"
        }

        /// サーバー用（OCR・対応表）の登録だけの行か
        var isServerOnly: Bool { kinds.isEmpty && !staticKinds.contains("admin") }

        /// 「アップロード・閲覧・管理」のような説明
        var kindsText: String {
            let labels = ["upload": "アップロード", "app": "閲覧", "admin": "管理", "ocr": "OCR", "index": "対応表"]
            return (kinds + staticKinds).compactMap { labels[$0] }.joined(separator: "・")
        }
    }

    struct PairCode: Decodable, Equatable {
        let code: String            // ABCD-EFGH の形
        let name: String
        let scopes: [String]
        let tokenTtl: Int?          // 受け取るトークンの寿命（秒）。nil = ずっと
        let expiresAt: Double       // このコードが使える期限
        let replaces: Bool          // 同じ名前の端末がすでにある（コードを使うと、その端末の登録が切れる）
        enum CodingKeys: String, CodingKey { case code, name, scopes, tokenTtl = "token_ttl", expiresAt = "expires_at", replaces }
    }

    /// 端末名に使える形か（英小文字・数字・ハイフンで32文字まで。先頭は英数字）。サーバーと同じ規則
    static func isValidDeviceName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 32 else { return false }
        let alnum = { (c: Unicode.Scalar) in ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        return alnum(first) && name.unicodeScalars.allSatisfy { alnum($0) || $0 == "-" }
    }

    // MARK: - 呼び出し（WireGuard 側の口）

    /// 登録コードを発行する。scopes は upload・app の一部。ttl は受け取るトークンの寿命（秒。nil = ずっと）
    static func issuePairCode(name: String, scopes: [String], ttl: Int?) async throws -> PairCode {
        guard isValidDeviceName(name) else { throw CouchImgError.badDeviceName }
        let (data, status) = try await adminSend("POST", "api/pair-codes",
                                                 json: ["name": name, "scopes": scopes, "ttl": ttl ?? NSNull()])
        if status == 400 { throw CouchImgError.badDeviceName }
        guard status == 201 else { throw error(for: status) }
        return try JSONDecoder().decode(PairCode.self, from: data)
    }

    static func devices() async throws -> [Device] {
        struct Reply: Decodable { let devices: [Device] }
        let (data, status) = try await adminSend("GET", "api/devices")
        guard status == 200 else { throw error(for: status) }
        return try JSONDecoder().decode(Reply.self, from: data).devices
    }

    /// その端末の upload・app を無効にする。管理用の登録が残るなら true を返す
    @discardableResult
    static func revokeDevice(name: String) async throws -> Bool {
        struct Reply: Decodable {
            let staticKinds: [String]
            enum CodingKeys: String, CodingKey { case staticKinds = "static_kinds" }
        }
        guard isValidDeviceName(name) else { throw CouchImgError.badDeviceName }
        let (data, status) = try await adminSend("DELETE", "api/devices/\(name)")
        if status == 404 { throw CouchImgError.deviceNotFound }
        guard status == 200 else { throw error(for: status) }
        return ((try? JSONDecoder().decode(Reply.self, from: data))?.staticKinds ?? []).contains("admin")
    }
}

// MARK: - 画面

struct CouchImgDevicesView: View {
    private enum Use: String, CaseIterable, Identifiable {
        case browser, app
        var id: String { rawValue }
        var label: String { self == .browser ? "アップロードだけ（ブラウザ・couchLog）" : "アップロードと閲覧（couchNotes）" }
        var scopes: [String] { self == .browser ? ["upload"] : ["upload", "app"] }
    }

    @State private var devices: [CouchImgService.Device] = []
    @State private var loaded = false
    @State private var isWorking = false
    @State private var message: String?

    @State private var newName = ""
    @State private var use = Use.browser
    @State private var oneHour = false
    @State private var issued: CouchImgService.PairCode?
    @State private var confirmReplace = false
    @State private var revoking: CouchImgService.Device?

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces).lowercased() }
    private var myName: String? { CouchImgService.deviceName }

    var body: some View {
        Form {
            Section(
                header: Text("端末を追加"),
                footer: Text("登録コード（8文字・5分・1回だけ有効）を出します。ブラウザは https://img.choiyaki.com/upload を開いて入力、couchNotes と couchLog はそれぞれの設定に入力します。端末名はアプリごとに別の名前にします（例: iphone-log）。借りた PC では「1時間だけ」を選んでください。")
            ) {
                TextField("端末名（例: win-home）", text: $newName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                Picker("使い方", selection: $use) {
                    ForEach(Use.allCases) { Text($0.label).tag($0) }
                }
                Picker("期限", selection: $oneHour) {
                    Text("ずっと").tag(false)
                    Text("1時間だけ").tag(true)
                }
                Button("登録コードを出す") {
                    if devices.contains(where: { $0.name == trimmedName && !$0.kinds.isEmpty }) { confirmReplace = true } else { issue() }
                }
                .disabled(!CouchImgService.isValidDeviceName(trimmedName) || isWorking)

                if let issued {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issued.code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Text("「\(issued.name)」用・\(issued.scopes == ["upload"] ? "アップロードだけ" : "アップロードと閲覧")・\(issued.tokenTtl == nil ? "期限なし" : "1時間だけ")")
                        Text("\(Self.time(issued.expiresAt)) まで有効（1回だけ使えます）")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
            }

            Section(
                header: Text("登録済みの端末"),
                footer: Text("無効にできるのは、アップロードと閲覧の登録です。管理（公開・削除）の登録は、サーバーで couchimg-token revoke <端末名> を実行して無効にします。")
            ) {
                if !loaded {
                    ProgressView()
                } else if devices.isEmpty {
                    Text("登録済みの端末はありません").foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(device.name).font(.body.monospaced())
                            if device.name == myName { Text("この端末").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(Self.detail(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !device.kinds.isEmpty {
                            Button("無効にする", role: .destructive) { revoking = device }
                        }
                    }
                    .contextMenu {
                        if !device.kinds.isEmpty {
                            Button("無効にする", role: .destructive) { revoking = device }
                        }
                    }
                }
            }
        }
        .navigationTitle("端末の追加と一覧")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isWorking)
            }
        }
        .task { await reload() }
        .alert("couchimg", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("同じ名前の端末があります", isPresented: $confirmReplace) {
            Button("登録し直す", role: .destructive) { issue() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(trimmedName)」はすでに登録されています。出したコードを使うと、いまの「\(trimmedName)」の登録は使えなくなります。別の端末なら、別の名前にしてください。")
        }
        .alert("この端末を無効にしますか？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { device in
            Button("無効にする", role: .destructive) { revoke(device) }
            Button("キャンセル", role: .cancel) {}
        } message: { device in
            Text(device.name == myName
                 ? "「\(device.name)」はいま使っているこの端末です。無効にすると、登録し直すまでアップロードも画像の表示もできなくなります。"
                 : "「\(device.name)」からのアップロード\(device.kinds.contains("app") ? "と画像の表示" : "")ができなくなります。もう一度使うには、登録コードを出し直します。")
        }
    }

    // MARK: - 表示

    private static func time(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }

    private static func day(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .numeric, time: .shortened)
    }

    private static func detail(_ device: CouchImgService.Device) -> String {
        var parts = [device.kindsText]
        if device.isServerOnly { parts.append("サーバー用") }
        if let at = device.expiresAt { parts.append("\(day(at)) まで") }
        if let at = device.lastUploadAt { parts.append("最後のアップロード \(day(at))") }
        return parts.joined(separator: " / ")
    }

    // MARK: - 操作

    private func reload() async {
        isWorking = true
        defer { isWorking = false; loaded = true }
        do { devices = try await CouchImgService.devices() } catch { message = error.localizedDescription }
    }

    private func issue() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                issued = try await CouchImgService.issuePairCode(name: trimmedName, scopes: use.scopes, ttl: oneHour ? 3600 : nil)
            } catch { message = error.localizedDescription }
        }
    }

    private func revoke(_ device: CouchImgService.Device) {
        isWorking = true
        Task { @MainActor in
            do {
                let adminRemains = try await CouchImgService.revokeDevice(name: device.name)
                message = adminRemains
                    ? "「\(device.name)」のアップロードと閲覧を無効にしました。管理（公開・削除）の登録は残っています。"
                    : "「\(device.name)」を無効にしました。"
            } catch { message = error.localizedDescription }
            isWorking = false
            await reload()
        }
    }
}
