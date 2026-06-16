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
    case httpError(Int)
    case noURL

    var errorDescription: String? {
        switch self {
        case .missingToken:   return "Gyazo アクセストークンが設定されていません。設定で登録してください。"
        case .httpError(let code): return "アップロードに失敗しました（\(code)）。"
        case .noURL:          return "アップロード結果に画像URLが含まれていませんでした。"
        }
    }
}

enum GyazoUploadService {
    static let tokenKey = "gyazo_access_token"

    /// 画像データを Gyazo にアップロードし、直リンクの画像URLを返す。
    static func upload(imageData: Data, filename: String, mimeType: String, token: String) async throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let http = response as? HTTPURLResponse else { throw GyazoUploadError.httpError(-1) }
        guard http.statusCode == 200 else { throw GyazoUploadError.httpError(http.statusCode) }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 直リンク画像URL（インラインプレビュー用）。無ければ permalink_url をフォールバック。
        guard let url = (json?["url"] as? String) ?? (json?["permalink_url"] as? String),
              !url.isEmpty else {
            throw GyazoUploadError.noURL
        }
        return url
    }
}
