//
//  GyazoUploadService.swift
//  couchNotes
//
//  画像を Gyazo にアップロードし、挿入用の直リンク画像URLを返す。
//  （Obsidian プラグイン「gyazo insert」を参考。直リンク url を採用してインラインプレビューを効かせる）
//

import Foundation

enum GyazoUploadError: LocalizedError {
    case missingToken
    case unauthorized
    case httpError(Int, String?)
    case noURL

    var errorDescription: String? {
        switch self {
        case .missingToken:   return "Gyazo アクセストークンが設定されていません。設定で登録してください。"
        case .unauthorized:
            return "Gyazo の認証に失敗しました（401）。設定のアクセストークンを再発行し、「Bearer 」を付けずに登録し直してください。"
        case .httpError(let code, let detail):
            let suffix = detail.map { "\n\($0)" } ?? ""
            return "アップロードに失敗しました（\(code)）。\(suffix)"
        case .noURL:          return "アップロード結果に画像URLが含まれていませんでした。"
        }
    }
}

enum GyazoUploadService {
    static let tokenKey = "gyazo_access_token"

    /// Authorization ヘッダ値をそのまま貼り付けても、トークン部分だけを保存・送信する。
    static func normalizedToken(_ value: String) -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.count >= 2,
           (token.first == "\"" && token.last == "\"" || token.first == "'" && token.last == "'") {
            token = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    /// 画像データを Gyazo にアップロードし、直リンクの画像URLを返す。
    static func upload(imageData: Data, filename: String, mimeType: String, token: String) async throws -> String {
        let trimmed = normalizedToken(token)
        guard !trimmed.isEmpty else { throw GyazoUploadError.missingToken }

        let boundary = "----CouchNotesGyazoBoundary\(UInt64(Date().timeIntervalSince1970 * 1000))"
        var request = URLRequest(url: URL(string: "https://upload.gyazo.com/api/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let header = "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"imagedata\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(mimeType)\r\n\r\n"
        body.append(Data(header.utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GyazoUploadError.httpError(-1, nil) }
        if http.statusCode == 401 { throw GyazoUploadError.unauthorized }
        guard http.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (json?["message"] as? String) ?? (json?["error"] as? String)
            throw GyazoUploadError.httpError(http.statusCode, detail)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 直リンク画像URL（インラインプレビュー用）。無ければ permalink_url をフォールバック。
        guard let url = (json?["url"] as? String) ?? (json?["permalink_url"] as? String),
              !url.isEmpty else {
            throw GyazoUploadError.noURL
        }
        return url
    }

    /// Gyazo の画像URL（直リンク i.gyazo.com/<id>.png ／ permalink gyazo.com/<id>）から画像IDを取り出す。
    /// Gyazo の画像でなければ nil。
    static func imageId(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              host == "gyazo.com" || host.hasSuffix(".gyazo.com") else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 32, name.allSatisfy({ $0.isHexDigit }) else { return nil }
        return name.lowercased()
    }

    /// GET /api/images/:id から取り出す情報。
    struct ImageInfo {
        /// Gyazo が付けた OCR テキスト。未処理・文字なしは nil
        var ocrText: String?
        /// アップロード日時（解釈できなければ nil）
        var createdAt: Date?
    }

    /// 画像の OCR テキストと作成日時を取得する。自分の画像でない（404）場合は nil。
    static func fetchImageInfo(imageId: String, token: String) async throws -> ImageInfo? {
        let trimmed = normalizedToken(token)
        guard !trimmed.isEmpty else { throw GyazoUploadError.missingToken }

        var request = URLRequest(url: URL(string: "https://api.gyazo.com/api/images/\(imageId)")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GyazoUploadError.httpError(-1, nil) }
        if http.statusCode == 401 { throw GyazoUploadError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw GyazoUploadError.httpError(http.statusCode, nil) }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ocr = json?["ocr"] as? [String: Any]
        let text = (ocr?["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ImageInfo(ocrText: text.isEmpty ? nil : text,
                         createdAt: (json?["created_at"] as? String).flatMap(parseDate))
    }

    /// created_at は ISO 8601（"2014-05-21T14:24:30+0000" 等）。区切りの揺れも許す。
    static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ssZ"] {
            df.dateFormat = format
            if let d = df.date(from: string) { return d }
        }
        return nil
    }
}
