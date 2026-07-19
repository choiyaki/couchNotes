import Foundation
import UIKit

// MARK: - 通知名

extension Notification.Name {
    /// 開いている詳細画面向け：特定ノートの本文が更新された。userInfo["noteId"]。
    static let noteDidChange = Notification.Name("couchNotes.noteDidChange")
    /// 一覧向け：ストア（追加/更新/削除）に変化があった。
    static let noteStoreDidChange = Notification.Name("couchNotes.noteStoreDidChange")
}

// MARK: - longpoll レスポンス

private struct ChangesResponse: Decodable {
    struct Result: Decodable {
        let id: String
        let deleted: Bool?
    }
    let results: [Result]
    let last_seq: String
}

// MARK: - リスナー本体

@MainActor
class ChangesListener: ObservableObject {
    static let shared = ChangesListener()

    @Published var isConnected = false

    /// 全件リコンシリエーション（安全網）の定期実行間隔。
    /// 通常起動はこの間 last_seq からの差分取得で追従し、全件突き合わせは走らせない。
    private static let reconcileInterval: TimeInterval = 24 * 3600

    private var listenerTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: - 公開 API

    func start() {
        guard listenerTask == nil || listenerTask!.isCancelled else { return }
        listenerTask = Task { await listenLoop() }
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        isConnected = false
    }

    // MARK: - longpoll ループ

    /// feed=longpoll で変更を待ち受けるループ
    /// 変更があれば即返す。なければ30秒後に空で返り、すぐ次のリクエストを送る
    private func listenLoop() async {
        // 前回終了時の last_seq から再開（無ければ現在から）。
        // これでアプリ停止中に起きた変更も取りこぼさない。
        let storedSeq = await NoteStore.shared.syncValue("last_seq")
        var since = storedSeq ?? "now"

        // まず未同期(dirty)を押し上げる（pull より前に必要・軽量）。
        let flushTimer = SyncTimer()
        await SyncEngine.shared.flush()
        syncLog.info("startup flush 完了 \(flushTimer.elapsedMs)ms")

        // 全件リコンシリエーション（安全網）は必要時のみ実施（レバー1）。
        // 通常起動は下の longpoll が last_seq からの差分で追従するため走らせない。
        // 実施する場合も longpoll を待たせないよう背後で流す（レバー3）。
        if await shouldFullReconcile(storedSeq: storedSeq) {
            Task { @MainActor in
                let t = SyncTimer()
                if await self.reconcile() { await self.stampReconcile() }
                syncLog.info("startup reconcile（背景）完了 \(t.elapsedMs)ms")
            }
        } else {
            syncLog.info("startup reconcile スキップ（last_seq から差分取得）")
        }
        var recovered = false   // listener がエラーから復帰したら押し上げ＋整合し直す

        while !Task.isCancelled {
            isConnected = true
            do {
                let response = try await fetchChanges(since: since)
                if recovered {
                    await SyncEngine.shared.flush()
                    if await reconcile() { await stampReconcile() }
                    recovered = false
                }

                // この応答バッチ中は同期範囲を一度だけ評価
                let scopeFolders = SyncScope.normalizedFolders

                // 対象ノートを「更新」と「ネイティブ削除」に仕分け（重複idは排除）
                var updateIDs: [String] = []
                var deleteIDs: [String] = []
                var seen = Set<String>()
                for event in response.results {
                    guard
                        event.id.hasSuffix(".md"),
                        !event.id.hasPrefix("h:"),
                        SyncScope.shouldSync(id: event.id, folders: scopeFolders),
                        seen.insert(event.id).inserted
                    else { continue }
                    if event.deleted == true { deleteIDs.append(event.id) }
                    else                     { updateIDs.append(event.id) }
                }

                var didChangeStore = false

                // 未同期のローカル変更（dirty／pendingDelete）はサーバ更新で上書き・復活させない。
                let protected = await NoteStore.shared.dirtyIDs()
                    .union(await NoteStore.shared.pendingDeleteIDs())
                updateIDs.removeAll { protected.contains($0) }

                // 更新分はバルク取得 → 一括 upsert。削除はネイティブ削除（トゥームストーン）の
                // deleted:true だけを信号にするため、差集合推定はしない（取得失敗を削除と誤判定しない）。
                if !updateIDs.isEmpty {
                    let records = try await CouchDBClient.shared.fetchNoteRecords(ids: updateIDs)
                    if !records.isEmpty {
                        await NoteStore.shared.upsertMany(records)
                        for r in records {
                            NotificationCenter.default.post(
                                name: .noteDidChange, object: nil, userInfo: ["noteId": r.id]
                            )
                        }
                        didChangeStore = true
                    }
                }

                for id in deleteIDs {
                    await NoteStore.shared.delete(id)
                    didChangeStore = true
                }

                if didChangeStore {
                    NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
                }

                // 全処理が成功してから last_seq を前進・保存する。
                // 途中で失敗した場合は同じ since から再試行し、変更を取りこぼさない。
                since = response.last_seq
                await NoteStore.shared.setSyncValue("last_seq", since)
            } catch is CancellationError {
                break
            } catch {
                // エラー時は5秒待って再試行。復帰後に整合（取りこぼした削除・更新の収束）。
                isConnected = false
                recovered = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
        isConnected = false
    }

    // MARK: - リコンシリエーション（背骨）

    /// サーバ（正本）とローカルの存在・世代を突き合わせて収束させる。
    /// _changes の取りこぼし（listener 断・seq 無効・長期オフライン）に対する最終保証。
    /// - Returns: サーバ側の一覧取得に成功したか（成功時のみ「実施済み」として時刻を刻める）。
    @discardableResult
    func reconcile() async -> Bool {
        let folders = SyncScope.normalizedFolders
        let serverRevs: [String: String]
        let liveRevsTimer = SyncTimer()
        do {
            serverRevs = try await CouchDBClient.shared.liveNoteRevs(folders: folders)
        } catch {
            syncLog.info("reconcile liveNoteRevs 失敗 \(liveRevsTimer.elapsedMs)ms")
            return false
        }
        syncLog.info("reconcile liveNoteRevs 完了 \(liveRevsTimer.elapsedMs)ms / スコープ内ノート \(serverRevs.count)件")

        let local = await NoteStore.shared.idRevMap()
        // 未同期ノートは保護：dirty（未送信編集）も pendingDelete（削除予定）も触らない。
        // dirty=削除/上書きしない、pendingDelete=サーバにまだ在ってもローカルへ復活させない。
        let protected = await NoteStore.shared.dirtyIDs()
            .union(await NoteStore.shared.pendingDeleteIDs())
        var didChange = false

        // 1) ローカルにあってサーバに無い → 削除（取りこぼした削除の収束）。スコープ内のみ。
        //    サーバ応答が空に見える場合は異常の可能性があるため、誤った全削除を避けて削除はスキップ。
        //    rev が空の行も削除しない：サーバに在ったことを一度も確認できていない行（ローカル先行
        //    作成の同期前など）は「サーバから消えた」とは判定できない（スナップショット取得と
        //    作成が交差した時に、作りたてのノートを誤削除しないための保険）。
        if !serverRevs.isEmpty {
            for (id, rev) in local
            where serverRevs[id] == nil && !rev.isEmpty && !protected.contains(id) && SyncScope.shouldSync(id: id, folders: folders) {
                await NoteStore.shared.delete(id)
                didChange = true
            }
        }

        // 2) サーバにあってローカルに無い／rev 不一致 → 取得して反映（存在＋世代同期）。保護対象は除く。
        let fetchIDs = serverRevs.compactMap { (id, srev) in
            (local[id] == srev || protected.contains(id)) ? nil : id
        }
        syncLog.info("reconcile 取得対象 \(fetchIDs.count)件（差分/新規）")
        let fetchTimer = SyncTimer()
        if !fetchIDs.isEmpty,
           let records = try? await CouchDBClient.shared.fetchNoteRecords(ids: fetchIDs),
           !records.isEmpty {
            syncLog.info("reconcile fetchNoteRecords 完了 \(fetchTimer.elapsedMs)ms / \(records.count)件")
            await NoteStore.shared.upsertMany(records)
            for r in records {
                NotificationCenter.default.post(
                    name: .noteDidChange, object: nil, userInfo: ["noteId": r.id]
                )
            }
            didChange = true
        }

        if didChange {
            NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        }
        return true
    }

    /// 全件リコンシリエーションの実施時刻を記録する（定期実行の判定に使う）。
    private func stampReconcile() async {
        await NoteStore.shared.setSyncValue("last_reconcile", String(Int(Date().timeIntervalSince1970)))
    }

    /// 全件リコンシリエーション（安全網）を今回実施すべきか。
    /// 初回（last_seq 未保存）は必須。以降は前回実施から一定時間経過で定期実行する。
    /// 通常起動は longpoll が last_seq からの差分で追従するため実施しない。
    private func shouldFullReconcile(storedSeq: String?) async -> Bool {
        guard let storedSeq, storedSeq != "now", !storedSeq.isEmpty else { return true }
        guard let raw = await NoteStore.shared.syncValue("last_reconcile"),
              let last = Double(raw) else { return true }
        return Date().timeIntervalSince1970 - last >= Self.reconcileInterval
    }

    // MARK: - longpoll リクエスト

    private func fetchChanges(since: String) async throws -> ChangesResponse {
        let request = try CouchDBClient.shared.makeChangesURLRequest(since: since)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CouchDBError.httpError(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                "_changes longpoll に失敗しました"
            )
        }
        guard let result = try? JSONDecoder().decode(ChangesResponse.self, from: data) else {
            throw CouchDBError.decodingError
        }
        return result
    }
}
