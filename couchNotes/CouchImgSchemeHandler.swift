//
//  CouchImgSchemeHandler.swift
//  couchNotes
//
//  編集画面（WKWebView）で couchimg の画像を表示するための独自スキーム couchimg:// の受け口。
//  WKWebView の <img> は認証ヘッダを付けられないので、Web 側は表示のときだけ URL を
//  couchimg://img/<id>.<拡張子> に読み替え、ここでトークンを付けて取りに行く。
//  トークンは Web 側（JS・URL）に一切渡らない。取得した画像はメモリの中にだけ置く。
//

import Foundation
import WebKit

final class CouchImgSchemeHandler: NSObject, WKURLSchemeHandler {
    /// ノートを開き直すたびに取り直さないための、メモリ上だけのキャッシュ（アプリを終了すると消える）
    private static let cache: NSCache<NSURL, CachedImage> = {
        let c = NSCache<NSURL, CachedImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private final class CachedImage {
        let data: Data
        let mimeType: String
        let isPublic: Bool
        init(data: Data, mimeType: String, isPublic: Bool) {
            self.data = data; self.mimeType = mimeType; self.isPublic = isPublic
        }
    }

    /// 進行中の要求。中止された要求に応答を返すと WebKit が例外を出すので、返す前に必ず確かめる。
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// 削除・公開の後に、古い内容を出さないようにする。
    static func forget(urlString: String) {
        guard let file = CouchImgService.imageFile(from: urlString) else { return }
        cache.removeObject(forKey: CouchImgService.baseURL.appendingPathComponent(file) as NSURL)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let remote = CouchImgService.remoteURL(fromSchemeURL: requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if let hit = Self.cache.object(forKey: remote as NSURL) {
            respond(urlSchemeTask, url: requestURL, data: hit.data, mimeType: hit.mimeType)
            Self.notifyVisibility(webView, remote: remote, isPublic: hit.isPublic)
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        active[key] = Task { @MainActor [weak self] in
            let result = try? await CouchImgService.fetchImage(remote)
            guard let self, self.active.removeValue(forKey: key) != nil else { return }   // 中止済み
            guard let result else {
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                return
            }
            Self.cache.setObject(
                CachedImage(data: result.data, mimeType: result.mimeType, isPublic: result.isPublic),
                forKey: remote as NSURL, cost: result.data.count)
            self.respond(urlSchemeTask, url: requestURL, data: result.data, mimeType: result.mimeType)
            Self.notifyVisibility(webView, remote: remote, isPublic: result.isPublic)
        }
    }

    /// 画像が公開されているかを編集画面へ知らせる（公開画像に枠を付け、メニューを「公開中」にするため）。
    /// 知らせるのは画像の URL と公開状態だけ。
    private static func notifyVisibility(_ webView: WKWebView, remote: URL, isPublic: Bool) {
        let payload: [String: Any] = ["type": "imageVisibility", "url": remote.absoluteString, "public": isPublic]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.couchNotesReceive(\(json));")
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let headers = ["Content-Type": mimeType, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
