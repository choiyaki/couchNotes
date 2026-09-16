//
//  ImageTextRecognizer.swift
//  couchNotes
//
//  画像内の文字を取り出す（エディタの「文字を取り込む」用）。
//  1. Gyazo の画像なら、Gyazo が付けた OCR テキストを API で取得する
//  2. Gyazo 以外の画像、または 1 が空・失敗なら、画像をダウンロードして端末の Vision で認識する
//

import Foundation
import Vision

enum ImageTextRecognizerError: LocalizedError {
    case downloadFailed
    case noText

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "画像を取得できませんでした。"
        case .noText:         return "画像から文字が見つかりませんでした。"
        }
    }
}

enum ImageTextRecognizer {
    static func recognize(url: String) async throws -> String {
        if let id = GyazoUploadService.imageId(from: url) {
            let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
            if !token.isEmpty,
               let text = try? await GyazoUploadService.fetchOCR(imageId: id, token: token) {
                return text
            }
        }
        let data = try await download(url)
        let text = try await visionText(from: data)
        guard !text.isEmpty else { throw ImageTextRecognizerError.noText }
        return text
    }

    private static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ImageTextRecognizerError.downloadFailed }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw ImageTextRecognizerError.downloadFailed
        }
        return data
    }

    /// Vision（日本語＋英語・高精度）で認識し、上から下・同じ高さなら左から右の順に行を並べる。
    static func visionText(from data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            // data から作ると EXIF の向きも Vision 側で解釈される
            try VNImageRequestHandler(data: data, options: [:]).perform([request])

            let items: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { obs in
                guard let s = obs.topCandidates(1).first?.string else { return nil }
                return (obs.boundingBox, s)
            }
            return orderedLines(items)
        }.value
    }

    /// boundingBox は左下原点の正規化座標。中心の高さが行の高さの半分以内なら同じ行として左から並べる。
    static func orderedLines(_ items: [(box: CGRect, text: String)]) -> String {
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for item in sorted {
            if let last = rows.last?.last,
               abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) / 2 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
