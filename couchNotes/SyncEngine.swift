//
//  SyncEngine.swift
//  couchNotes
//
//  オフライン書き込みの同期ワーカ。未同期（dirty）ノートをサーバへ押し上げる。
//  「Remote CouchDB が正本／ローカル SQLite はライトバックキャッシュ」という原則のもと、
//  ローカルに dirty として永続化された編集を、オンライン時にまとめて押し上げて clean に戻す。
//

import Foundation

// MARK: - 依存の抽象化（テストでフェイク差し替え可能にするための窓口）

/// SyncEngine がリモート（CouchDB）に対して必要とする操作だけを写したプロトコル。
protocol SyncRemoteClient {
    func deleteNote(id: String) async throws
    func saveNoteContentChecked(id: String, path: String, text: String,
                                ctime: Double, baseRev: String?) async throws -> String
    func fetchNoteRecord(id: String) async throws -> NoteRecord?
    func currentLeafRev(id: String) async throws -> String?
}

/// SyncEngine がローカルストア（NoteStore）に対して必要とする操作だけを写したプロトコル。
protocol SyncLocalStore {
    func pendingDeleteIDs() async -> Set<String>
    func dirtyIDs() async -> Set<String>
    func editingNote(_ id: String) async -> StoredNote?
    func removeRow(_ id: String) async
    func markClean(_ id: String, rev: String?) async
}

// 既存型はシグネチャが一致するので空の準拠で済む。
extension CouchDBClient: SyncRemoteClient {}
extension NoteStore: SyncLocalStore {}

// MARK: - 同期ワーカ本体

@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    private let remote: SyncRemoteClient
    private let store: SyncLocalStore
    private let isOnline: @MainActor () -> Bool

    /// 本番はシングルトン依存を既定値に、テストはフェイクを注入する。
    init(remote: SyncRemoteClient = CouchDBClient.shared,
         store: SyncLocalStore = NoteStore.shared,
         isOnline: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isOnline }) {
        self.remote = remote
        self.store = store
        self.isOnline = isOnline
    }

    /// 詳細画面で現在編集中のノート。その画面の save() が押し上げるため、ワーカは二重処理を避けて飛ばす。
    var activeNoteId: String?

    private var flushing = false

    /// 未同期（dirty）と削除予定（pendingDelete）をサーバへ押し上げる。オフライン時・実行中は何もしない。
    /// 失敗は据え置き、ローカルに残して次のトリガーで再試行する（データは失わない）。
    func flush() async {
        guard isOnline(), !flushing else { return }
        flushing = true
        defer { flushing = false }

        var changed = false
        defer { if changed { NotificationCenter.default.post(name: .noteStoreDidChange, object: nil) } }

        // 1) 削除予定 → サーバ削除（ネイティブ削除）→ 行を物理削除
        for id in await store.pendingDeleteIDs() {
            do {
                try await remote.deleteNote(id: id)
                await store.removeRow(id)
                changed = true
            } catch CouchDBError.networkError {
                return   // オフラインに転落。次回トリガーで再試行。
            } catch {
                continue   // 一時的な失敗は据え置き、次回再試行。
            }
        }

        // 2) 未同期編集 → 楽観ロックで push（開いているノートは詳細画面の save() に委ねて飛ばす）
        for id in await store.dirtyIDs() where id != activeNoteId {
            guard let s = await store.editingNote(id) else { continue }
            let nowMs      = Date().timeIntervalSince1970 * 1000
            let createdSec = Int((s.ctime ?? nowMs) / 1000)
            let updatedSec = Int((s.mtime ?? nowMs) / 1000)
            let extra      = (s.extra ?? "").isEmpty ? [] : s.extra!.components(separatedBy: "\n")
            let fullText   = FrontmatterParser.compose(
                createdSec: createdSec, updatedSec: updatedSec, extra: extra, body: s.body
            )
            let path = s.path ?? id
            let ctime = s.ctime ?? nowMs
            do {
                let newRev = try await remote.saveNoteContentChecked(
                    id: id, path: path, text: fullText, ctime: ctime, baseRev: s.rev)
                await store.markClean(id, rev: newRev)
                changed = true
            } catch CouchDBError.networkError {
                return
            } catch CouchDBError.httpError(409, _) {
                // 競合。サーバ側が削除済み（削除 vs 編集）なら編集保全で墓標の上に再作成。
                // 編集 vs 編集なら dirty のまま据え置き（その都度バナーは出さず、ノートを開いた時に解決）。
                if (try? await remote.fetchNoteRecord(id: id)) == nil,
                   let tomb = try? await remote.currentLeafRev(id: id),
                   let newRev = try? await remote.saveNoteContentChecked(
                       id: id, path: path, text: fullText, ctime: ctime, baseRev: tomb) {
                    await store.markClean(id, rev: newRev)
                    changed = true
                }
            } catch {
                continue
            }
        }
    }
}
