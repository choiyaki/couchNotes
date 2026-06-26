//
//  SyncEngineTests.swift
//  couchNotesTests
//
//  SyncEngine.flush() の競合解決ロジックを、フェイク依存で固定する回帰テスト。
//  「Remote CouchDB が正本／ローカルはライトバックキャッシュ」という設計の肝
//  （削除 vs 編集の墓標再作成、編集 vs 編集の据え置き、409 ハンドリング）を守る。
//

import XCTest
@testable import couchNotes

// MARK: - フェイク依存

/// リモート（CouchDB）のフェイク。挙動を仕込め、呼び出しを記録する。
final class FakeRemote: SyncRemoteClient {
    var onDelete:  (String) async throws -> Void           = { _ in }
    var onSave:    (_ id: String, _ baseRev: String?) async throws -> String = { _, _ in "rev-new" }
    var onFetch:   (String) async throws -> NoteRecord?    = { _ in nil }
    var onLeafRev: (String) async throws -> String?        = { _ in nil }

    private(set) var deletedIDs:    [String]   = []
    private(set) var savedBaseRevs: [String?]  = []
    private(set) var fetchCount     = 0
    private(set) var leafRevCount   = 0

    func deleteNote(id: String) async throws {
        deletedIDs.append(id)
        try await onDelete(id)
    }
    func saveNoteContentChecked(id: String, path: String, text: String,
                                ctime: Double, baseRev: String?) async throws -> String {
        savedBaseRevs.append(baseRev)
        return try await onSave(id, baseRev)
    }
    func fetchNoteRecord(id: String) async throws -> NoteRecord? {
        fetchCount += 1
        return try await onFetch(id)
    }
    func currentLeafRev(id: String) async throws -> String? {
        leafRevCount += 1
        return try await onLeafRev(id)
    }
}

/// ローカルストア（NoteStore）のフェイク。
final class FakeStore: SyncLocalStore {
    var pendingDelete: Set<String> = []
    var dirty:         Set<String> = []
    var notes:         [String: StoredNote] = [:]

    private(set) var removedIDs:  [String] = []
    private(set) var markedClean: [(id: String, rev: String?)] = []

    func pendingDeleteIDs() async -> Set<String> { pendingDelete }
    func dirtyIDs() async -> Set<String> { dirty }
    func editingNote(_ id: String) async -> StoredNote? { notes[id] }
    func removeRow(_ id: String) async { removedIDs.append(id); pendingDelete.remove(id) }
    func markClean(_ id: String, rev: String?) async { markedClean.append((id, rev)); dirty.remove(id) }
}

private func makeStoredNote(rev: String? = "rev-1") -> StoredNote {
    StoredNote(body: "hello", ctime: 1_000_000, mtime: 2_000_000, extra: nil, path: "note.md", rev: rev)
}

// MARK: - テスト

@MainActor
final class SyncEngineTests: XCTestCase {

    private func makeEngine(_ remote: FakeRemote, _ store: FakeStore, online: Bool = true) -> SyncEngine {
        SyncEngine(remote: remote, store: store, isOnline: { online })
    }

    /// 1) オフライン → 何もしない
    func testOfflineDoesNothing() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.pendingDelete = ["a"]
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote()
        await makeEngine(remote, store, online: false).flush()

        XCTAssertTrue(remote.deletedIDs.isEmpty)
        XCTAssertTrue(remote.savedBaseRevs.isEmpty)
        XCTAssertTrue(store.removedIDs.isEmpty)
        XCTAssertTrue(store.markedClean.isEmpty)
    }

    /// 2) pendingDelete 正常 → deleteNote 後に removeRow
    func testPendingDeleteHappyPath() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.pendingDelete = ["a"]
        await makeEngine(remote, store).flush()

        XCTAssertEqual(remote.deletedIDs, ["a"])
        XCTAssertEqual(store.removedIDs, ["a"])
    }

    /// 3) 削除中に networkError → 中断、行は残る（次回再試行）
    func testDeleteNetworkErrorStops() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.pendingDelete = ["a"]
        remote.onDelete = { _ in throw CouchDBError.networkError(URLError(.notConnectedToInternet)) }
        await makeEngine(remote, store).flush()

        XCTAssertEqual(remote.deletedIDs, ["a"])   // 試みたが
        XCTAssertTrue(store.removedIDs.isEmpty)    // 行は消えていない
    }

    /// 4) dirty 押し上げ正常 → markClean(newRev)
    func testDirtyPushHappyPath() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote(rev: "rev-1")
        remote.onSave = { _, _ in "rev-2" }
        await makeEngine(remote, store).flush()

        XCTAssertEqual(remote.savedBaseRevs, ["rev-1"])
        XCTAssertEqual(store.markedClean.count, 1)
        XCTAssertEqual(store.markedClean.first?.id, "b")
        XCTAssertEqual(store.markedClean.first?.rev, "rev-2")
    }

    /// 5) 押し上げ中に networkError → 中断、dirty 維持
    func testPushNetworkErrorStops() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote()
        remote.onSave = { _, _ in throw CouchDBError.networkError(URLError(.timedOut)) }
        await makeEngine(remote, store).flush()

        XCTAssertTrue(store.markedClean.isEmpty)
    }

    /// 6) activeNoteId はスキップ（詳細画面の save() に委ねる）
    func testActiveNoteIsSkipped() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote()
        let engine = makeEngine(remote, store)
        engine.activeNoteId = "b"
        await engine.flush()

        XCTAssertTrue(remote.savedBaseRevs.isEmpty)
        XCTAssertTrue(store.markedClean.isEmpty)
    }

    /// 7) 409 = 削除 vs 編集 → 墓標 rev で再保存して markClean（編集保全の再作成）
    func testConflictDeleteVsEditRecreatesOnTombstone() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote(rev: "rev-1")
        remote.onSave = { _, baseRev in
            if baseRev == "rev-1" { throw CouchDBError.httpError(409, "conflict") } // 通常 push は競合
            return "rev-tomb-2"                                                      // 墓標上の再作成は成功
        }
        remote.onFetch   = { _ in nil }            // サーバに本文なし＝削除済み
        remote.onLeafRev = { _ in "rev-tomb-1" }   // 墓標 rev あり
        await makeEngine(remote, store).flush()

        XCTAssertEqual(remote.savedBaseRevs, ["rev-1", "rev-tomb-1"]) // 通常→墓標 の2回
        XCTAssertEqual(store.markedClean.count, 1)
        XCTAssertEqual(store.markedClean.first?.rev, "rev-tomb-2")
    }

    /// 8) 409 = 編集 vs 編集 → dirty 据え置き（markClean されない・墓標経路に入らない）
    func testConflictEditVsEditLeavesDirty() async {
        let remote = FakeRemote(); let store = FakeStore()
        store.dirty = ["b"]; store.notes["b"] = makeStoredNote(rev: "rev-1")
        remote.onSave  = { _, _ in throw CouchDBError.httpError(409, "conflict") }
        remote.onFetch = { _ in
            NoteRecord(id: "b", path: "note.md", mtime: 3_000_000, ctime: 1_000_000,
                       size: 5, content: "newer", rev: "rev-2")   // サーバに新しい版が在る
        }
        await makeEngine(remote, store).flush()

        XCTAssertEqual(remote.fetchCount, 1)
        XCTAssertTrue(store.markedClean.isEmpty)   // 据え置き
        XCTAssertEqual(remote.leafRevCount, 0)     // 墓標経路に入っていない
    }
}
