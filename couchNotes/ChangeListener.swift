import Foundation
import UIKit

// MARK: - 通知名

extension Notification.Name {
    static let noteDidChange = Notification.Name("couchNotes.noteDidChange")
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
        var since = "now"

        while !Task.isCancelled {
            isConnected = true
            do {
                let response = try await fetchChanges(since: since)
                since = response.last_seq   // 次のリクエストはここから

                for event in response.results {
                    guard !Task.isCancelled else { return }
                    guard
                        event.id.hasSuffix(".md"),
                        !event.id.hasPrefix("h:"),
                        event.deleted != true
                    else { continue }

                    // キャッシュ済みのノートだけ再取得
                    guard NoteCache.shared.has(event.id) else { continue }

                    if let fresh = try? await CouchDBClient.shared.fetchNoteContent(id: event.id) {
                        NoteCache.shared.set(event.id, content: fresh)
                        NotificationCenter.default.post(
                            name: .noteDidChange,
                            object: nil,
                            userInfo: ["noteId": event.id]
                        )
                    }
                }
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
