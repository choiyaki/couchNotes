import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import couchNotes

final class CouchImgServiceTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"

    // MARK: - URL の判定

    func testImageFileAcceptsOnlyOurHostAndShape() {
        XCTAssertEqual(CouchImgService.imageFile(from: "https://img.choiyaki.com/\(id).jpg"), "\(id).jpg")
        XCTAssertEqual(CouchImgService.imageFile(from: "https://IMG.CHOIYAKI.COM/\(id.uppercased()).PNG"), "\(id).png")
        XCTAssertEqual(CouchImgService.imageId(from: "https://img.choiyaki.com/\(id).gif"), id)

        let bad = [
            "http://img.choiyaki.com/\(id).jpg",                    // https でない
            "https://img.choiyaki.com.evil.example/\(id).jpg",      // 偽のホスト
            "https://evil.example/img.choiyaki.com/\(id).jpg",
            "https://img.choiyaki.com/\(id).jpg?sig=x",             // クエリ付き
            "https://img.choiyaki.com/\(id).heic",                  // 受け付けない拡張子
            "https://img.choiyaki.com/\(id)",                       // 拡張子なし
            "https://img.choiyaki.com/a/\(id).jpg",                 // 余計な階層
            "https://img.choiyaki.com/\(id.dropLast()).jpg",        // 桁数違い
            "https://i.gyazo.com/\(id).png",
            "",
        ]
        for url in bad { XCTAssertNil(CouchImgService.imageFile(from: url), url) }
    }

    func testSchemeURLMapsToHTTPS() {
        let url = URL(string: "couchimg://img/\(id).webp")!
        XCTAssertEqual(CouchImgService.remoteURL(fromSchemeURL: url)?.absoluteString,
                       "https://img.choiyaki.com/\(id).webp")
        // 形の違うものは、どこにも取りに行かない
        for s in ["couchimg://img/../etc/passwd", "couchimg://img/\(id).jpg/x", "https://img/\(id).jpg",
                  "couchimg://img/api/me", "couchimg://img/"] {
            XCTAssertNil(CouchImgService.remoteURL(fromSchemeURL: URL(string: s)!), s)
        }
    }

    func testTokenIsAttachedOnlyToOurHost() {
        KeychainManager.shared.save(key: CouchImgService.appTokenKey, value: "TESTTOKEN", thisDeviceOnly: true)
        defer { KeychainManager.shared.delete(key: CouchImgService.appTokenKey) }
        let ours = CouchImgService.imageRequest(for: URL(string: "https://img.choiyaki.com/\(id).jpg")!)
        XCTAssertEqual(ours.value(forHTTPHeaderField: "Authorization"), "Bearer TESTTOKEN")
        for s in ["https://i.gyazo.com/\(id).png", "http://img.choiyaki.com/\(id).jpg",
                  "https://img.choiyaki.com.evil.example/\(id).jpg"] {
            XCTAssertNil(CouchImgService.imageRequest(for: URL(string: s)!).value(forHTTPHeaderField: "Authorization"), s)
        }
    }

    // MARK: - 公開状態

    func testPublicIsReadFromCacheControl() {
        XCTAssertTrue(CouchImgService.isPublicCacheControl("public, max-age=31536000, immutable"))
        XCTAssertTrue(CouchImgService.isPublicCacheControl("max-age=60, Public"))
        XCTAssertFalse(CouchImgService.isPublicCacheControl("private, no-store"))
        XCTAssertFalse(CouchImgService.isPublicCacheControl("no-store, x-public-ish"))
        XCTAssertFalse(CouchImgService.isPublicCacheControl(nil))
    }

    // MARK: - ノートのパス

    func testNotePathIsPercentEncodedASCII() {
        let encoded = CouchImgService.encodedNotePath("日記/2026-10-02 メモ.md")
        XCTAssertEqual(encoded?.removingPercentEncoding, "日記/2026-10-02 メモ.md")
        XCTAssertTrue(encoded!.allSatisfy { $0.isASCII && $0 != " " && $0 != "\n" })
        XCTAssertNil(CouchImgService.encodedNotePath(nil))
        XCTAssertNil(CouchImgService.encodedNotePath(""))
    }

    // MARK: - 送る前の準備

    /// 向き 6（表示のとき右に90度回す）・GPS・機種名つきの JPEG を作る
    private func makeJPEG(width: Int, height: Int, orientation: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 139.69, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "CIMG_CANARY_MAKE"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "CIMG_CANARY_COMMENT"],
        ]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testPrepareStripsMetadataAndBakesOrientation() throws {
        let src = makeJPEG(width: 400, height: 200, orientation: 6)
        XCTAssertNotNil(properties(src)[kCGImagePropertyGPSDictionary], "見本に GPS が入っている")
        XCTAssertNotNil(src.range(of: Data("CIMG_CANARY".utf8)))

        let out = try CouchImgService.prepareForUpload(src)
        XCTAssertEqual(out.mimeType, "image/jpeg")
        let p = properties(out.data)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary], "GPS が消えている")
        XCTAssertNil(out.data.range(of: Data("CIMG_CANARY".utf8)), "機種名・コメントが消えている")
        XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int ?? 1, 1, "向きは画素に反映済み")
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 200, "縦横が入れ替わっている")
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 400)
        XCTAssertEqual(p[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1", "sRGB に直している")
    }

    func testPrepareShrinksHugePhotos() throws {
        let out = try CouchImgService.prepareForUpload(makeJPEG(width: 8064, height: 6048, orientation: 1))
        let p = properties(out.data)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, CouchImgService.maxLongEdge)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 2250)
    }

    func testPrepareDoesNotEnlargeSmallPhotos() throws {
        let p = properties(try CouchImgService.prepareForUpload(makeJPEG(width: 320, height: 240, orientation: 1)).data)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 320)
    }

    func testPreparePassesThroughPNGAndGIF() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let outPNG = try CouchImgService.prepareForUpload(png)
        XCTAssertEqual(outPNG.mimeType, "image/png")
        XCTAssertEqual(outPNG.data, png, "PNG はそのまま（手書きメモ・スクリーンショット）")

        let gif = Data("GIF89a".utf8) + Data([1, 0, 1, 0, 0, 0, 0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b])
        let outGIF = try CouchImgService.prepareForUpload(gif)
        XCTAssertEqual(outGIF.mimeType, "image/gif")
        XCTAssertEqual(outGIF.data, gif, "GIF はコマを保つためそのまま")
    }

    func testPrepareRejectsNonImages() {
        XCTAssertThrowsError(try CouchImgService.prepareForUpload(Data("<html>".utf8)))
        XCTAssertThrowsError(try CouchImgService.prepareForUpload(Data()))
    }

    // MARK: - アップロード先の切り替え

    func testBackendDefaultsToGyazo() {
        let saved = UserDefaults.standard.string(forKey: ImageUploader.backendKey)
        defer { UserDefaults.standard.set(saved, forKey: ImageUploader.backendKey) }
        UserDefaults.standard.removeObject(forKey: ImageUploader.backendKey)
        XCTAssertEqual(ImageUploader.backend, .gyazo)
        UserDefaults.standard.set("couchimg", forKey: ImageUploader.backendKey)
        XCTAssertEqual(ImageUploader.backend, .couchimg)
        UserDefaults.standard.set("nazo", forKey: ImageUploader.backendKey)
        XCTAssertEqual(ImageUploader.backend, .gyazo)
    }
}

/// サーバーの応答の形（../couchimg/docs/DESIGN.md 3.2）を読めること。サーバー側のテストが返す形をそのまま写したもの。
final class CouchImgAPIDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testImageInfo() throws {
        let info = try decode(CouchImgService.ImageInfo.self, """
        {"id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","url":"https://img.choiyaki.com/a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.png","public":false,
         "ext":"png","mime":"image/png","width":640,"height":480,"bytes":12345,"created_at":1800000000,"uploaded_by":"iphone","upload_source":null,
         "ocr":{"status":"pending","text":null,"revision":0,"edited":false,"model":null,"updated_at":null,"truncated":false,"queue":{"ahead":2,"eta_seconds":720}},
         "notes":[{"doc_id":"publish/a.md","path":"Publish/a.md","kind":"embed","public":true}],"suggest_publish":true}
        """)
        XCTAssertEqual(info.ocr.queue, .init(ahead: 2, etaSeconds: 720))
        XCTAssertEqual(info.notes.first?.isPublic, true)
        XCTAssertTrue(info.suggestPublish)
        XCTAssertNil(info.uploadSource)
        XCTAssertFalse(info.isPublic)
    }

    func testListChangesHints() throws {
        let list = try decode(CouchImgService.ImageList.self, """
        {"items":[{"id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","ext":"jpg","public":true,"created_at":5,"width":1,"height":2,"bytes":3,
          "uploaded_by":"mac","upload_source":"share","ocr_status":"done","ocr_edited":false,"notes":0,"snippet":"…合計…","url":"https://img.choiyaki.com/a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.jpg"}],"next":"5:a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"}
        """)
        XCTAssertEqual(list.items.first?.snippet, "…合計…")
        XCTAssertEqual(list.next, "5:a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")

        let changes = try decode(CouchImgService.Changes.self, """
        {"gen":"0123456789abcdef0123456789abcdef","reset":true,"next":6,"more":false,"items":[
          {"id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","seq":5,"deleted":false,"ext":"png","public":false,"created_at":1,"ocr_status":"done","ocr_text":"直した","ocr_revision":2,"ocr_edited":true},
          {"id":"b0b1b2b3b4b5b6b7b8b9babbbcbdbebf","seq":6,"deleted":true}]}
        """)
        XCTAssertEqual(changes.items.map(\.ocrText), ["直した", nil])
        XCTAssertEqual(changes.items.map(\.deleted), [false, true])
        XCTAssertTrue(changes.reset)

        let hints = try decode(CouchImgService.Hints.self, """
        {"index_at":null,"unattached":[],"public_only_in_private_notes":[],"private_in_public_notes":[{"id":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","url":"https://img.choiyaki.com/a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.png","created_at":9}]}
        """)
        XCTAssertNil(hints.indexAt)
        XCTAssertEqual(hints.privateInPublicNotes.count, 1)
    }

    func testDevicesAndPairCode() throws {
        struct Reply: Decodable { let devices: [CouchImgService.Device] }
        let devices = try decode(Reply.self, """
        {"devices":[
          {"name":"couchagent","kinds":[],"static_kinds":["ocr"],"created_at":null,"expires_at":null,"last_upload_at":null},
          {"name":"iphone","kinds":["upload","app"],"static_kinds":["admin"],"created_at":1800000000,"expires_at":null,"last_upload_at":null},
          {"name":"win-home","kinds":["upload"],"static_kinds":[],"created_at":1800000000,"expires_at":1800003600,"last_upload_at":1800000010}]}
        """).devices
        XCTAssertEqual(devices.map(\.isServerOnly), [true, false, false])
        XCTAssertEqual(devices.map(\.kindsText), ["OCR", "アップロード・閲覧・管理", "アップロード"])
        XCTAssertEqual(devices[2].expiresAt, 1_800_003_600)

        let code = try decode(CouchImgService.PairCode.self, """
        {"code":"ABCD-EFGH","name":"win-home","scopes":["upload"],"token_ttl":null,"expires_at":1800000300,"replaces":true}
        """)
        XCTAssertEqual(code.code, "ABCD-EFGH")
        XCTAssertNil(code.tokenTtl)
        XCTAssertTrue(code.replaces)
    }

    func testDeviceNameFollowsTheServerRule() {
        for ok in ["a", "win-home", "0mac", String(repeating: "a", count: 32)] {
            XCTAssertTrue(CouchImgService.isValidDeviceName(ok), ok)
        }
        for bad in ["", "-a", "Win", "自宅", "a b", "a_b", "a/b", "..", "ａ", String(repeating: "a", count: 33)] {
            XCTAssertFalse(CouchImgService.isValidDeviceName(bad), bad)
        }
    }

    func testPreviewTargetOnlyForOurImages() {
        let id = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
        XCTAssertEqual(ImagePreviewTarget(urlString: "https://img.choiyaki.com/\(id).jpg"), ImagePreviewTarget(id: id, ext: "jpg"))
        XCTAssertEqual(ImagePreviewTarget(urlString: "https://IMG.choiyaki.com/\(id.uppercased()).PNG")?.url.absoluteString,
                       "https://img.choiyaki.com/\(id).png")
        XCTAssertNil(ImagePreviewTarget(urlString: "https://i.gyazo.com/\(id).png"))
        XCTAssertNil(ImagePreviewTarget(urlString: "https://img.choiyaki.com.evil.example/\(id).png"))
    }
}
