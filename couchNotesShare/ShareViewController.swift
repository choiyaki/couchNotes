//
//  ShareViewController.swift
//  couchNotesShare
//
//  共有シートから、写真を couchimg（自分のサーバー）に上げる。設計は ../couchimg/docs/DESIGN.md 4.5。
//  - 上げるだけ（ノートには貼らない）。送り終えたら「N枚送りました」と出して閉じる。クリップボードは書き換えない
//  - 使うのは、couchNotes 本体が共有の置き場（Keychain の共有グループ）に写したアップロード専用のトークンだけ。
//    閲覧用・管理用のトークンには届かない
//  - 送る前に、向きを画素に反映した JPEG に作り直して、位置情報などの付加情報を消す
//    （本体の CouchImgService.prepareForUpload と同じ処理。拡張機能は本体のコードを使えないので写してある）
//

import ImageIO
import Security
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let closeButton = UIButton(type: .system)
    private var task: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = "couchimg に送っています…"
        spinner.startAnimating()
        closeButton.setTitle("閉じる", for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.isHidden = true
        closeButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, label, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        task = Task { [weak self] in await self?.run() }
    }

    private func finish() {
        task?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// 結果を出す。成功なら少し見せてから自動で閉じる。失敗があれば「閉じる」を押すまで残す。
    private func show(_ text: String, autoClose: Bool) {
        spinner.stopAnimating()
        label.text = text
        if autoClose {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
        } else {
            closeButton.isHidden = false
        }
    }

    private func run() async {
        guard let token = ShareUploader.token() else {
            show("couchimg に登録されていません。\ncouchNotes の 設定 →「画像アップロード」で登録してください（登録済みなら、couchNotes を一度開いてからやり直してください）。", autoClose: false)
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard !providers.isEmpty else {
            show("送れる画像がありません。", autoClose: false)
            return
        }

        var sent = 0
        var firstError: String?
        // 1枚ずつ順に送る（大きな写真を同時に何枚も展開しない。サーバーも端末ごとに同時1件まで）
        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { return }
            if providers.count > 1 { label.text = "couchimg に送っています…（\(index + 1) / \(providers.count)）" }
            do {
                let data = try await ShareUploader.loadData(from: provider)
                try await ShareUploader.upload(data, token: token)
                sent += 1
            } catch let error as ShareUploader.Failure {
                if firstError == nil { firstError = error.message }
                if error == .unauthorized { break }   // 登録が無効なら、残りを送っても同じ
            } catch {
                if firstError == nil { firstError = "サーバーに繋がりませんでした。" }
            }
        }
        if let firstError {
            let done = sent > 0 ? "\(sent)枚送りました。" : ""
            show("\(done)\(providers.count - sent)枚は送れませんでした。\n\(firstError)", autoClose: false)
        } else {
            show("\(sent)枚送りました", autoClose: true)
        }
    }
}

// MARK: - アップロード

enum ShareUploader {
    enum Failure: Error, Equatable {
        case cannotRead, unauthorized, rejected, tooLarge, busy, http(Int)

        var message: String {
            switch self {
            case .cannotRead:   return "画像を読み込めませんでした。"
            case .unauthorized: return "couchimg の登録が無効になっています。couchNotes の設定で登録し直してください。"
            case .rejected:     return "受け付けられない形式の画像です。"
            case .tooLarge:     return "画像が大きすぎます（20MB まで）。"
            case .busy:         return "サーバーが混み合っているか、1日の上限に達しました。少し待ってからやり直してください。"
            case .http(let code): return "サーバーとの通信に失敗しました（\(code)）。"
            }
        }
    }

    private static let uploadURL = URL(string: "https://img.choiyaki.com/upload")!
    private static let maxLongEdge = 3000

    // 本体（ShareExtensionToken.swift）と同じ値にする
    private static let accessGroup = "H8BCFLBJVR.com.github.choiyaki.couchNotes.shared"
    private static let service = "com.github.choiyaki.couchNotes.share"
    private static let account = "couchimg_upload_token"

    /// 本体が共有の置き場に写した、アップロード専用のトークン
    static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func loadData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Failure.cannotRead) }
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func upload(_ imageData: Data, token: String) async throws {
        let prepared = try prepareForUpload(imageData)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(prepared.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("share", forHTTPHeaderField: "X-Upload-Source")
        let (_, response) = try await session.upload(for: request, from: prepared.data)
        switch (response as? HTTPURLResponse)?.statusCode ?? -1 {
        case 201: return
        case 401: throw Failure.unauthorized
        case 413: throw Failure.tooLarge
        case 415: throw Failure.rejected
        case 408, 429, 503: throw Failure.busy
        case let code: throw Failure.http(code)
        }
    }

    /// 送る画像を整える（本体の CouchImgService.prepareForUpload と同じ）。
    /// - GIF: そのまま / PNG: 向きの指定がなく大きすぎなければそのまま（付加情報はサーバーが消す）
    /// - それ以外（JPEG・HEIC など）: 向きを画素に反映し、長辺 3,000 以下の sRGB の JPEG に作り直す。付加情報は付けない
    static func prepareForUpload(_ data: Data) throws -> (data: Data, mimeType: String) {
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (data, "image/gif") }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw Failure.cannotRead }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if isPNG, orientation == 1, max(width, height) <= maxLongEdge * 2, data.count <= 15 * 1024 * 1024 {
            return (data, "image/png")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxLongEdge, max(width, height, 1)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: oriented.width, height: oriented.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.cannotRead
        }
        let rect = CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height)
        context.setFillColor(UIColor.white.cgColor)   // 透明な部分は白にする（JPEG は透明を持てない）
        context.fill(rect)
        context.draw(oriented, in: rect)
        guard let flattened = context.makeImage() else { throw Failure.cannotRead }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.cannotRead
        }
        CGImageDestinationAddImage(dest, flattened, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotRead }
        return (out as Data, "image/jpeg")
    }
}
