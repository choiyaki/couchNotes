import XCTest
@testable import couchNotes

/// 画像内の文字（OCR）の取り込みと、それを使ったノートの検索（../couchimg/docs/DESIGN.md 4.4・5章 2-5 c）。
/// シミュレータの中のアプリの DB を使う（終わったら、作ったノートは消す）。
final class ImageOCRStoreTests: XCTestCase {
    private typealias Change = CouchImgService.Change
    private let a = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    private let b = "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
    private let noteA = "__ocrtest/with-image-a.md"
    private let noteB = "__ocrtest/with-image-b.md"
    private let gen = String(repeating: "1", count: 32)

    private func page(_ items: [Change], next: Int, reset: Bool = false, gen: String? = nil) -> CouchImgService.Changes {
        .init(gen: gen ?? self.gen, reset: reset, items: items, next: next, more: false)
    }
    private func text(_ id: String, _ seq: Int, _ text: String?) -> Change {
        .init(id: id, seq: seq, deleted: false, ocrStatus: "done", ocrText: text)
    }
    private func note(_ id: String, _ body: String) -> NoteRecord {
        .init(id: id, path: id, mtime: 1_000, ctime: 1_000, size: body.utf8.count, content: body)
    }
    private func found(_ query: String) async -> [NoteItem] {
        await NoteStore.shared.searchBodies(query).filter { $0.id.hasPrefix("__ocrtest/") }
    }

    override func setUp() async throws {
        await NoteStore.shared.bootstrap()
        // 手元を空にして始める（reset = サーバーの DB が作り直されたときと同じ動き）
        await NoteStore.shared.applyOCRChanges(page([], next: 0, reset: true))
        await NoteStore.shared.upsert(note(noteA, "買い物のメモ\n\n![](https://img.choiyaki.com/\(a).png)\n"))
        await NoteStore.shared.upsert(note(noteB, "別のノート。リンクだけ https://img.choiyaki.com/\(b).jpg\n```\n![](https://img.choiyaki.com/\(a).png)\n```\n"))
    }

    override func tearDown() async throws {
        await NoteStore.shared.removeRow(noteA)
        await NoteStore.shared.removeRow(noteB)
        await NoteStore.shared.applyOCRChanges(page([], next: 0, reset: true))
    }

    func testAppliedTextIsSearchableThroughTheNoteThatEmbedsTheImage() async {
        await NoteStore.shared.applyOCRChanges(page([text(a, 1, "レシート 合計 １，９８０円 Coffee Shop"), text(b, 2, "会議室の予約表")], next: 2))
        let position = await NoteStore.shared.ocrSyncPosition()
        XCTAssertEqual(position.since, 2)
        XCTAssertEqual(position.gen, gen)

        // 本文には無い語が、貼ってある画像の文字で見つかる。一覧には「画像内の文字: …」と出る
        let hits = await found("レシート")
        XCTAssertEqual(hits.map(\.id), [noteA])
        XCTAssertEqual(hits.first?.preview?.hasPrefix("画像内の文字: "), true)
        XCTAssertEqual(hits.first?.preview?.contains("レシート"), true)
        // コードブロックの中の URL は「貼ってある」に数えない（noteB には出ない）。リンクだけの画像でも見つかる
        let linked = await found("会議室")
        XCTAssertEqual(linked.map(\.id), [noteB])
        // 2文字以下・全角と半角の違い・英字の大文字小文字
        let two = await found("合計")
        XCTAssertEqual(two.map(\.id), [noteA])
        let width = await found("1,980円")
        XCTAssertEqual(width.map(\.id), [noteA])
        let caseless = await found("coffee shop")
        XCTAssertEqual(caseless.map(\.id), [noteA])
        // 複数の語: 本文の語と画像の語の組み合わせ（AND）
        let both = await found("買い物 レシート")
        XCTAssertEqual(both.map(\.id), [noteA])
        let neither = await found("買い物 会議室")
        XCTAssertEqual(neither.map(\.id), [])
        // 本文で一致したノートの表示は、これまでどおり本文
        let body = await found("買い物")
        XCTAssertEqual(body.first?.preview?.hasPrefix("画像内の文字"), false)
        // 記号を入れてもエラーにならない
        for q in ["\"", "レシート OR 会議", "100%", "*", "a_b"] { _ = await found(q) }
    }

    func testApplyingTheSamePageTwiceOrOutOfOrderDoesNotLoseOrDuplicate() async {
        let first = page([text(a, 1, "最初の文字")], next: 1)
        let second = page([text(a, 5, "直した文字")], next: 5)
        await NoteStore.shared.applyOCRChanges(first)
        await NoteStore.shared.applyOCRChanges(second)
        // 取り込みの途中で落ちて、同じ回・古い回をもう一度受け取った
        await NoteStore.shared.applyOCRChanges(second)
        await NoteStore.shared.applyOCRChanges(page([text(a, 1, "最初の文字")], next: 5))
        let current = await NoteStore.shared.ocrText(forImage: a)
        XCTAssertEqual(current, "直した文字", "古い番号の内容で上書きしない")
        let old = await found("最初の文字")
        XCTAssertEqual(old.map(\.id), [])
        let new = await found("直した文字")
        XCTAssertEqual(new.map(\.id), [noteA], "同じノートが二重に出ない")
        let position = await NoteStore.shared.ocrSyncPosition()
        XCTAssertEqual(position.since, 5)
    }

    func testDeletedImagesAndEmptyTextLeaveNoSearchHits() async {
        await NoteStore.shared.applyOCRChanges(page([text(a, 1, "消える文字"), text(b, 2, "空になる文字")], next: 2))
        await NoteStore.shared.applyOCRChanges(page([
            .init(id: a, seq: 3, deleted: true, ocrStatus: nil, ocrText: nil), text(b, 4, ""),
        ], next: 4))
        let gone = await found("消える文字")
        XCTAssertEqual(gone.map(\.id), [])
        let emptied = await found("空になる")
        XCTAssertEqual(emptied.map(\.id), [])
        let deleted = await NoteStore.shared.ocrText(forImage: a)
        XCTAssertNil(deleted)
        // 削除の後に、遅れて届いた古い内容では生き返らない
        await NoteStore.shared.applyOCRChanges(page([text(a, 1, "消える文字")], next: 4))
        let stillGone = await found("消える文字")
        XCTAssertEqual(stillGone.map(\.id), [])
    }

    func testResetStartsOverAndNoteRemovalDropsItsImageRefs() async {
        await NoteStore.shared.applyOCRChanges(page([text(a, 7, "古い世代の文字")], next: 7))
        // サーバーの DB が戻された: 世代が変わり、番号は小さくなっていても最初から取り直す
        let newGen = String(repeating: "2", count: 32)
        await NoteStore.shared.applyOCRChanges(page([text(a, 1, "新しい世代の文字")], next: 1, reset: true, gen: newGen))
        let old = await found("古い世代")
        XCTAssertEqual(old.map(\.id), [])
        let new = await found("新しい世代")
        XCTAssertEqual(new.map(\.id), [noteA])
        let position = await NoteStore.shared.ocrSyncPosition()
        XCTAssertEqual(position.since, 1)
        XCTAssertEqual(position.gen, newGen)

        // 画像の行をノートから消すと、そのノートは画像の文字では見つからなくなる
        await NoteStore.shared.upsert(note(noteA, "買い物のメモ（画像を外した）"))
        let detached = await found("新しい世代")
        XCTAssertEqual(detached.map(\.id), [])
        let refs = await NoteStore.shared.notes(forImage: a)
        XCTAssertEqual(refs.map(\.id), [])
        let existing = await NoteStore.shared.existingNoteIDs([noteA, "__ocrtest/none.md"])
        XCTAssertEqual(existing, [noteA])
    }
}
