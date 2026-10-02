import XCTest
@testable import couchNotes

/// 本文から画像 URL を抜き出す規則。例は imageRefs.cases.json（サーバー側 ../couchimg/server/test/imageRefs.cases.json の写し）。
/// サーバー（JavaScript）と端末（Swift）が同じ例の表で同じ結果になることを確かめる。
final class ImageRefsTests: XCTestCase {
    private struct Cases: Decodable {
        struct Config: Decodable { let hosts: [String]; let idPattern: String }
        struct Expect: Decodable { let id: String; let ext: String?; let kind: String }
        struct Case: Decodable { let name: String; let config: String?; let text: String; let expect: [Expect] }
        let ids: [String: String]
        let configs: [String: Config]
        let cases: [Case]
    }

    private func load() throws -> Cases {
        // テストはシミュレータ（Mac の上）で動くので、このファイルの隣の JSON をそのまま読める
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("imageRefs.cases.json")
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    func testSharedCases() throws {
        let cases = try load()
        XCTAssertGreaterThan(cases.cases.count, 70)
        func fill(_ s: String) -> String {
            cases.ids.reduce(s) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
        for c in cases.cases {
            let conf = try XCTUnwrap(cases.configs[c.config ?? "couchimg"])
            let got = ImageRefs.extract(fill(c.text), config: .init(hosts: conf.hosts, idPattern: conf.idPattern))
            let want = try c.expect.map {
                ImageRef(id: try XCTUnwrap(cases.ids[$0.id]), ext: $0.ext, kind: try XCTUnwrap(ImageRef.Kind(rawValue: $0.kind)))
            }
            XCTAssertEqual(got, want, c.name)
        }
    }

    func testConfigsMatchSharedFile() throws {
        let cases = try load()
        XCTAssertEqual(cases.configs["couchimg"]?.hosts, ImageRefs.couchimg.hosts)
        XCTAssertEqual(cases.configs["couchimg"]?.idPattern, ImageRefs.couchimg.idPattern)
        XCTAssertEqual(cases.configs["gyazo"]?.hosts, ImageRefs.gyazo.hosts)
    }

    func testNastyInputsFinishQuickly() {
        let url = "https://img.choiyaki.com/a0a1a2a3a4a5a6a7a8a9aaabacadaeaf.png"
        let nasty = [
            String(repeating: "![", count: 100_000), String(repeating: "`", count: 200_000), String(repeating: "` ", count: 100_000),
            String(repeating: "<!-", count: 70_000), String(repeating: "<img ", count: 40_000), String(repeating: "[a]: ", count: 40_000),
            String(repeating: "\\", count: 200_000), "![" + String(repeating: "[x]", count: 60_000), String(repeating: "```\n", count: 50_000),
            String(repeating: "`\n\n", count: 70_000), (1...600).map { String(repeating: "`", count: $0) }.joined(separator: " "),
        ]
        for s in nasty {
            let start = Date()
            let got = ImageRefs.extract(s + "\n\n![](\(url))")
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, String(s.prefix(8)))
            XCTAssertLessThanOrEqual(got.count, 1)
        }
    }
}
