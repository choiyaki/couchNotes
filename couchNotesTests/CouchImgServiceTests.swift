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
