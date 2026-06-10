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
        var since = await NoteStore.shared.syncValue("last_seq") ?? "now"

        while !Task.isCancelled {
            isConnected = true
            do {
                let response = try await fetchChanges(since: since)

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

                // 更新分はバルク取得 → 一括 upsert。LiveSync のソフト削除（deleted:true）は
                // 結果に含まれないので、要求 id との差集合を削除として扱う。
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
                    let returned = Set(records.map { $0.id })
                    for id in updateIDs where !returned.contains(id) { deleteIDs.append(id) }
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
                // エラー時は5秒待って再試行
                isConnected = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
        isConnected = false
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
