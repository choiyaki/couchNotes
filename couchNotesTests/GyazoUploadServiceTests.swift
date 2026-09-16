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
}
