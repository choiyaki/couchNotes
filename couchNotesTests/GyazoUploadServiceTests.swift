import XCTest
@testable import couchNotes

final class GyazoUploadServiceTests: XCTestCase {
    func testNormalizedTokenTrimsWhitespace() {
        XCTAssertEqual(GyazoUploadService.normalizedToken("  abc123\n"), "abc123")
    }

    func testNormalizedTokenRemovesBearerPrefixCaseInsensitively() {
        XCTAssertEqual(GyazoUploadService.normalizedToken("Bearer abc123"), "abc123")
        XCTAssertEqual(GyazoUploadService.normalizedToken("bearer   abc123  "), "abc123")
    }

    func testNormalizedTokenRemovesWrappingQuotes() {
        XCTAssertEqual(GyazoUploadService.normalizedToken("\"abc123\""), "abc123")
        XCTAssertEqual(GyazoUploadService.normalizedToken("'abc123'"), "abc123")
    }

    func testImageIdFromDirectAndPermalinkURLs() {
        let id = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(GyazoUploadService.imageId(from: "https://i.gyazo.com/\(id).png"), id)
        XCTAssertEqual(GyazoUploadService.imageId(from: "https://gyazo.com/\(id)"), id)
    }

    func testImageIdRejectsNonGyazoURLs() {
        let id = "0123456789abcdef0123456789abcdef"
        XCTAssertNil(GyazoUploadService.imageId(from: "https://example.com/\(id).png"))
        XCTAssertNil(GyazoUploadService.imageId(from: "https://i.gyazo.com/not-an-id.png"))
    }

    func testOrderedLinesGroupsSameRowLeftToRight() {
        // 左下原点: y が大きいほど上
        let items: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.1, y: 0.40, width: 0.3, height: 0.05), "二行目"),
            (CGRect(x: 0.5, y: 0.80, width: 0.3, height: 0.05), "右"),
            (CGRect(x: 0.1, y: 0.81, width: 0.3, height: 0.05), "左"),
        ]
        XCTAssertEqual(ImageTextRecognizer.orderedLines(items), "左 右\n二行目")
    }
}
