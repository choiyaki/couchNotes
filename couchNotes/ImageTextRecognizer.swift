//
//  ImageTextRecognizer.swift
//  couchNotes
//
//  画像内の文字を取り出す（エディタの「文字を取り込む」・手書きメモ用）。
//  1. Gyazo の画像なら、Gyazo が付けた OCR テキストを API で取得する（精度が高いのでこちらが基本）。
//     Gyazo の OCR はアップロード後しばらくしてから付くので、アップロード直後の画像は
//     結果が出るまで数秒おきに問い合わせて待つ。
//  2. Gyazo 以外の画像、または待っても空・失敗なら、端末の Vision で認識する
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
    /// Gyazo の OCR を待つ最長時間と問い合わせ間隔
    static let gyazoWaitLimit: TimeInterval = 30
    static let gyazoPollInterval: UInt64 = 3_000_000_000
    /// これより新しい Gyazo 画像は「OCR がまだ付いていないだけ」とみなして待つ
    static let recentUploadWindow: TimeInterval = 180

    /// - Parameters:
    ///   - localImage: Vision に渡す画像（手書きメモの白地＋線だけの画像など）。nil なら url からダウンロード
    ///   - justUploaded: いまアップロードした画像。作成日時に関わらず Gyazo の OCR を待つ
    static func recognize(url: String, localImage: Data? = nil, justUploaded: Bool = false) async throws -> String {
        if let id = GyazoUploadService.imageId(from: url) {
            let token = KeychainManager.shared.load(key: GyazoUploadService.tokenKey) ?? ""
            if !token.isEmpty, let text = await gyazoText(imageId: id, token: token, justUploaded: justUploaded) {
                return text
            }
        }
        let data: Data
        if let localImage { data = localImage } else { data = try await download(url) }
        let text = try await visionText(from: data)
        guard !text.isEmpty else { throw ImageTextRecognizerError.noText }
        return text
    }

    /// Gyazo の OCR テキスト。最近アップロードされた画像で未処理なら、上限時間まで待つ。
    private static func gyazoText(imageId: String, token: String, justUploaded: Bool) async -> String? {
        let deadline = Date().addingTimeInterval(gyazoWaitLimit)
        while true {
            guard let info = try? await GyazoUploadService.fetchImageInfo(imageId: imageId, token: token) else {
                return nil   // 通信失敗・自分の画像でない → Vision へ
            }
            if let text = info.ocrText { return text }
            let recent = justUploaded
                || (info.createdAt.map { Date().timeIntervalSince($0) < recentUploadWindow } ?? false)
            guard recent, Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: gyazoPollInterval)
            if Task.isCancelled { return nil }
        }
    }

    private static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ImageTextRecognizerError.downloadFailed }
        // couchimg の非公開画像はトークンを付けて取る（それ以外の URL は従来どおり）
        guard let data = try? await CouchImgService.fetchImage(url).data else {
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
