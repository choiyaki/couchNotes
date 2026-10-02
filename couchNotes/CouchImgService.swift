//
//  CouchImgService.swift
//  couchNotes
//
//  自分のサーバー（couchimg, https://img.choiyaki.com）への画像アップロード・取得・公開・削除。
//  設計は ../couchimg/docs/DESIGN.md。
//  - トークンは端末ごと・種類ごと（upload / app / admin）。登録コードと引き換えに受け取り、Keychain に置く
//  - アップロード直後は常に非公開。非公開画像は app のトークンを付けて取得する
//  - 公開・削除は WireGuard 側の口（10.9.0.10:8751）でだけ受け付けられる
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum CouchImgError: LocalizedError {
    case notRegistered
    case adminNotRegistered
    case badCode
    case unauthorized
    case rejected
    case tooLarge
    case busy
    case notFound
    case adminUnreachable
    case cannotPrepare
    case badDeviceName
    case deviceNotFound
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "この端末は couchimg に登録されていません。設定 →「画像アップロード」で登録コードを入力してください。"
        case .adminNotRegistered:
            return "公開・削除には管理用の登録が必要です。設定 →「画像アップロード」で、WireGuard を繋いだ状態で管理用の登録コードを入力してください。"
        case .badCode:
            return "登録コードが違うか、期限（5分）が切れています。コードを出し直してください。"
        case .unauthorized:
            return "couchimg の登録が無効になっています。設定 →「画像アップロード」で登録し直してください。"
        case .rejected:
            return "この画像は受け付けられませんでした（対応していない形式です）。"
        case .tooLarge:
            return "画像が大きすぎます（20MB まで）。"
        case .busy:
            return "サーバーが混み合っているか、1日の上限に達しました。少し待ってからやり直してください。"
        case .notFound:
            return "画像が見つかりません（すでに削除されている可能性があります）。"
        case .adminUnreachable:
            return "サーバーの管理用の口に繋がりません。WireGuard を繋いでからやり直してください。"
        case .cannotPrepare:
            return "画像を読み込めませんでした。"
        case .badDeviceName:
            return "端末名は、英小文字・数字・ハイフンで32文字までにしてください（例: win-home）。"
        case .deviceNotFound:
            return "その端末には、無効にできる登録がありません（すでに無効か、期限が切れています）。"
        case .httpError(let code):
            return "サーバーとの通信に失敗しました（\(code)）。"
        }
    }
}

enum CouchImgService {
    static let host = "img.choiyaki.com"
    static let baseURL = URL(string: "https://img.choiyaki.com")!
    /// WireGuard 側の口。WireGuard のトンネルの中なので平文の HTTP（Info.plist の NSAllowsLocalNetworking で許可）
    static let adminBaseURL = URL(string: "http://10.9.0.10:8751")!
    /// 編集画面（WKWebView）で画像を表示するときだけ使う独自スキーム。ノート本文の URL は https のまま
    static let scheme = "couchimg"

    static let uploadTokenKey = "couchimg_upload_token"
    static let appTokenKey = "couchimg_app_token"
    static let adminTokenKey = "couchimg_admin_token"
    private static let deviceNameKey = "couchimg_device_name"

    /// サーバーの上限（4,000万画素）より十分小さくする。長辺がこれを超える写真は縮める
    static let maxLongEdge = 3000

    // MARK: - 登録の状態

    static var deviceName: String? { UserDefaults.standard.string(forKey: deviceNameKey) }
    static var isRegistered: Bool { token(uploadTokenKey) != nil }
    static var hasAppToken: Bool { token(appTokenKey) != nil }
    static var hasAdminToken: Bool { token(adminTokenKey) != nil }

    static func token(_ key: String) -> String? {
        guard let t = KeychainManager.shared.load(key: key), !t.isEmpty else { return nil }
        return t
    }

    /// この端末に置いたトークンを消す（サーバー側の無効化は couchimg-token revoke で行う）
    static func forgetRegistration() {
        for key in [uploadTokenKey, appTokenKey, adminTokenKey] { KeychainManager.shared.delete(key: key) }
        UserDefaults.standard.removeObject(forKey: deviceNameKey)
        syncShareExtensionToken()
    }

    /// 共有シートの拡張機能に渡すアップロード専用トークンの写しを、今の登録に合わせる。
    /// 登録・登録の消去のときと、起動のとき（拡張機能を足す前からの登録を写すため）に呼ぶ。
    static func syncShareExtensionToken() {
        ShareExtensionToken.sync(token(uploadTokenKey))
    }

    // MARK: - 通信

    /// キャッシュをディスクに残さない設定（非公開画像を端末の保存領域に残さないため）
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    static func error(for status: Int) -> CouchImgError {
        switch status {
        case 401: return .unauthorized
        case 403: return .badCode
        case 404: return .notFound
        case 413: return .tooLarge
        case 415: return .rejected
        case 429, 503: return .busy
        default: return .httpError(status)
        }
    }

    // MARK: - 端末の登録（登録コード）

    /// 入力の揺れ（空白・ハイフン・小文字）はサーバーが吸収する
    private static func pairRequest(base: URL, code: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("pair"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        return request
    }

    private static func parsePairResponse(_ data: Data) -> (name: String, tokens: [String: String])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              let tokens = json["tokens"] as? [String: String] else { return nil }
        return (name, tokens)
    }

    /// 登録コードと引き換えに、この端末専用のトークン（upload・app）を受け取って保存する。端末名を返す。
    @discardableResult
    static func pair(code: String) async throws -> String {
        let (data, status) = try await send(pairRequest(base: baseURL, code: code, timeout: 20))
        guard status == 200, let result = parsePairResponse(data) else { throw error(for: status) }
        // 登録し直しのときは、古い種類のトークンを残さない
        for key in [uploadTokenKey, appTokenKey] { KeychainManager.shared.delete(key: key) }
        if let t = result.tokens["upload"] { save(t, key: uploadTokenKey) }
        if let t = result.tokens["app"] { save(t, key: appTokenKey) }
        UserDefaults.standard.set(result.name, forKey: deviceNameKey)
        syncShareExtensionToken()
        return result.name
    }

    /// 管理用（公開・削除）のトークンを受け取る。WireGuard を繋いだ状態でだけ届く。
    static func pairAdmin(code: String) async throws {
        let data: Data, status: Int
        do {
            (data, status) = try await send(pairRequest(base: adminBaseURL, code: code, timeout: 8))
        } catch {
            throw CouchImgError.adminUnreachable
        }
        guard status == 200, let result = parsePairResponse(data), let t = result.tokens["admin"] else {
            throw self.error(for: status)
        }
        save(t, key: adminTokenKey)
    }

    private static func save(_ token: String, key: String) {
        KeychainManager.shared.save(key: key, value: token, thisDeviceOnly: true)
    }

    /// 登録がサーバー側でまだ有効かを確かめる。
    static func checkRegistration() async throws {
        guard let t = token(appTokenKey) ?? token(uploadTokenKey) else { throw CouchImgError.notRegistered }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me"))
        request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        let (_, status) = try await send(request)
        guard status == 200 else { throw error(for: status) }
    }

    // MARK: - URL の判定

    /// couchimg の画像 URL（https://img.choiyaki.com/<32桁の16進>.<拡張子>）から「<id>.<拡張子>」を取り出す。
    /// ホストは完全一致（img.choiyaki.com.evil.example などは不可）。
    static func imageFile(from urlString: String) -> String? {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host, url.query == nil, url.fragment == nil else { return nil }
        return validFile(String(url.path.dropFirst()))
    }

    static func imageId(from urlString: String) -> String? {
        imageFile(from: urlString).map { String($0.prefix(32)) }
    }

    /// 編集画面用の URL（couchimg://img/<id>.<拡張子>）から、取りに行く https の URL を作る。
    static func remoteURL(fromSchemeURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme,
              let file = validFile(String(url.path.dropFirst())) else { return nil }
        return baseURL.appendingPathComponent(file)
    }

    private static func validFile(_ name: String) -> String? {
        let lower = name.lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 32, parts[0].allSatisfy({ $0.isHexDigit }),
              ["jpg", "png", "webp", "gif"].contains(String(parts[1])) else { return nil }
        return lower
    }

    // MARK: - 画像の取得

    /// couchimg の画像なら app のトークンを付けた要求を返す（公開画像はトークンがなくても取れる）。
    /// それ以外の URL はそのまま。
    static func imageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == host, let t = token(appTokenKey) {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 画像を取得する。couchimg の画像は、ディスクにキャッシュを残さない通信で取る。
    /// isPublic は couchimg の画像が公開されているか（それ以外の URL では常に false）。
    static func fetchImage(_ url: URL) async throws -> (data: Data, mimeType: String, isPublic: Bool) {
        let isOurs = url.host?.lowercased() == host
        let (data, response) = try await (isOurs ? session : URLSession.shared).data(for: imageRequest(for: url))
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, !data.isEmpty else { throw error(for: http?.statusCode ?? -1) }
        return (data, http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                isOurs && isPublicCacheControl(http?.value(forHTTPHeaderField: "Cache-Control")))
    }

    /// サーバーは公開画像に「public, max-age=…, immutable」、非公開画像に「private, no-store」を付けて返す。
    /// 公開状態はこのヘッダで見分ける（問い合わせの通信を増やさない）。
    static func isPublicCacheControl(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.lowercased().split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "public" }
    }

    // MARK: - アップロード

    /// ノートのパスはヘッダに日本語をそのまま入れられないので、パーセントエンコードして送る。
    static func encodedNotePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 画像をアップロードし、ノートに貼る URL を返す。notePath は「どのノートから上げたか」の手がかり（なくてもよい）。
    static func upload(imageData: Data, notePath: String?) async throws -> String {
        guard let t = token(uploadTokenKey) else { throw CouchImgError.notRegistered }
        let prepared = try prepareForUpload(imageData)

        var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        request.setValue(prepared.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("couchnotes", forHTTPHeaderField: "X-Upload-Source")
        if let encoded = encodedNotePath(notePath) { request.setValue(encoded, forHTTPHeaderField: "X-Note-Path") }

        let (data, response) = try await session.upload(for: request, from: prepared.data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 201,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String, imageFile(from: url) != nil else { throw error(for: status) }
        return url
    }

    // MARK: - 公開・削除（WireGuard 側の口）

    /// WireGuard 側の口への要求（admin のトークン）。繋がらなければ adminUnreachable。
    static func adminSend(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let t = token(adminTokenKey) else { throw CouchImgError.adminNotRegistered }
        var request = URLRequest(url: adminBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        do { return try await send(request) } catch { throw CouchImgError.adminUnreachable }
    }

    private static func adminRequest(_ method: String, _ path: String) async throws {
        let (_, status) = try await adminSend(method, path)
        guard status == 200 else { throw error(for: status) }
    }

    /// 公開にする。取り消せない（一方通行）。
    static func publish(urlString: String) async throws {
        guard let id = imageId(from: urlString) else { throw CouchImgError.notFound }
        try await adminRequest("POST", "api/images/\(id)/publish")
    }

    /// サーバーから削除する（ファイルも消える）。ノートの本文は変えない。
    static func delete(urlString: String) async throws {
        guard let id = imageId(from: urlString) else { throw CouchImgError.notFound }
        try await adminRequest("DELETE", "api/images/\(id)")
    }

    // MARK: - 送る前の準備（位置情報などの付加情報を消す）

    /// 送る画像を整える（サーバーでも必ず消すが、端末から出す前にも消す）。
    /// - GIF: そのまま（動く GIF のコマを保つ。付加情報はサーバーが消す）
    /// - PNG: 向きの指定がなく大きすぎなければそのまま（スクリーンショット・手書きメモ）
    /// - それ以外（JPEG・HEIC など）: 向きを画素に反映し、sRGB の JPEG に作り直す。付加情報は付けない
    static func prepareForUpload(_ data: Data) throws -> (data: Data, mimeType: String) {
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (data, "image/gif") }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw CouchImgError.cannotPrepare }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if isPNG, orientation == 1, max(width, height) <= maxLongEdge * 2, data.count <= 15 * 1024 * 1024 {
            return (data, "image/png")
        }

        // 向きを反映し、長辺を上限以下に縮めた画像を作る（元より大きくはしない）
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxLongEdge, max(width, height, 1)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CouchImgError.cannotPrepare
        }
        // sRGB に直して描き直す（広色域の写真の色がくすまないように。サーバーは JPEG の色のプロファイルを捨てる）
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: oriented.width, height: oriented.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CouchImgError.cannotPrepare
        }
        let rect = CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height)
        context.setFillColor(UIColor.white.cgColor)   // 透明な部分は白にする（JPEG は透明を持てない）
        context.fill(rect)
        context.draw(oriented, in: rect)
        guard let flattened = context.makeImage() else { throw CouchImgError.cannotPrepare }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CouchImgError.cannotPrepare
        }
        CGImageDestinationAddImage(dest, flattened, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CouchImgError.cannotPrepare }
        return (out as Data, "image/jpeg")
    }
}

// MARK: - アップロード先の切り替え（Gyazo / couchimg）

/// 画像のアップロード先。問題が出たら Gyazo に戻せるよう、設定で切り替える（移行が終わったら外す）。
enum ImageUploader {
    enum Backend: String {
        case gyazo, couchimg
    }

    static let backendKey = "imageUploadBackend"

    static var backend: Backend {
        Backend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .gyazo
    }

    private static var gyazoToken: String {
        KeychainManager.shared.load(key: GyazoUploadService.tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// アップロードできない理由（設定が足りない）。できるなら nil。
    static func notReadyMessage() -> String? {
        switch backend {
        case .gyazo:
            return gyazoToken.isEmpty
                ? "Gyazo アクセストークンが未設定です。設定 →「画像アップロード」で登録してください。" : nil
        case .couchimg:
            return CouchImgService.isRegistered ? nil : CouchImgError.notRegistered.errorDescription
        }
    }

    /// アップロードして、ノートに貼る画像 URL を返す。
    static func upload(imageData: Data, filename: String, mimeType: String, notePath: String?) async throws -> String {
        switch backend {
        case .gyazo:
            return try await GyazoUploadService.upload(
                imageData: imageData, filename: filename, mimeType: mimeType, token: gyazoToken)
        case .couchimg:
            return try await CouchImgService.upload(imageData: imageData, notePath: notePath)
        }
    }
}
