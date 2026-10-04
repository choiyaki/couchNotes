//
//  ChunkSplitTests.swift
//  couchNotesTests
//
//  本文を断片（LiveSync の leaf）に切る処理の回帰テスト。
//  以前は UTF-8 のバイト数だけで切っていたので、100KB を超えるノートで、切れ目が日本語の文字の
//  途中に来ると断片が空になり、本文の一部が消えていた。「連結すると元と一致する」を固定する。
//

import XCTest
@testable import couchNotes

final class ChunkSplitTests: XCTestCase {
    private let limit = 102_400   // 本番の断片の大きさ

    private func check(_ text: String, maxBytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        let pieces = CouchDBClient.splitUTF8(text, maxBytes: maxBytes)
        XCTAssertEqual(pieces.joined(), text, "連結すると元の本文と1文字も違わない", file: file, line: line)
        for p in pieces {
            XCTAssertLessThanOrEqual(p.utf8.count, maxBytes, "各断片は上限以下", file: file, line: line)
        }
        if !text.isEmpty {
            XCTAssertFalse(pieces.contains(""), "空の断片を作らない", file: file, line: line)
        }
    }

    func test切れ目が日本語の文字の途中に来ても本文が欠けない() {
        // 「あ」は3バイト。先頭に1〜3文字の ASCII を置いて、切れ目が文字の1・2バイト目に来る場合を全部試す
        for pad in 0...3 {
            let text = String(repeating: "a", count: pad) + String(repeating: "あ", count: 40_000)   // 約120KB
            XCTAssertGreaterThan(text.utf8.count, limit)
            check(text, maxBytes: limit)
        }
    }

    func test絵文字と結合文字でも欠けない() {
        let unit = "👨‍👩‍👧‍👦が🇯🇵で e\u{301} と𠮷野家"     // 4バイト文字・結合・サロゲートの外の漢字
        check(String(repeating: unit, count: 5_000), maxBytes: limit)
        // 小さい上限で、あらゆる位置に切れ目を作る
        for max in 4...40 { check(String(repeating: unit, count: 20), maxBytes: max) }
    }

    func test上限以下の本文は1つの断片のまま() {
        let text = String(repeating: "あ", count: 1_000)
        XCTAssertEqual(CouchDBClient.splitUTF8(text, maxBytes: limit), [text])
        XCTAssertEqual(CouchDBClient.splitUTF8("", maxBytes: limit), [""], "空の本文も断片を1つ作る（これまでと同じ）")
    }

    func testASCIIだけならこれまでと同じ位置で切れる() {
        let text = String(repeating: "x", count: limit * 2 + 10)
        let pieces = CouchDBClient.splitUTF8(text, maxBytes: limit)
        XCTAssertEqual(pieces.map { $0.utf8.count }, [limit, limit, 10])
    }
}
