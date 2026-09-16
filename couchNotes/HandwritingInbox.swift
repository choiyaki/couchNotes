//
//  HandwritingInbox.swift
//  couchNotes
//
//  アプリの外（URL スキーム couchnotes://handwrite・ホーム画面メニュー）から始める手書きメモの受け渡し役。
//  - captureRequest: NoteListView がキャンバスを全画面で出す
//  - pendingInsert:  書き込み先のノート画面がエディタ準備後に末尾へ挿入する（HandwritingResult の挿入経路は段階Aと同じ）
//

import Foundation

@MainActor
final class HandwritingInbox: ObservableObject {
    static let shared = HandwritingInbox()
    private init() {}

    struct CaptureRequest: Identifiable {
        let id = UUID()
        /// 書き込み先のパス。nil なら今日の日付ノート
        let path: String?
    }

    struct PendingInsert {
        let id = UUID()
        let noteId: String
        let result: HandwritingResult
    }

    @Published var captureRequest: CaptureRequest?
    @Published var pendingInsert: PendingInsert?

    /// noteId のノート宛ての挿入待ちがあれば取り出す（大文字小文字は区別しない＝LiveSync の ID は小文字）
    func takePendingInsert(for noteId: String) -> HandwritingResult? {
        guard let p = pendingInsert, p.noteId.lowercased() == noteId.lowercased() else { return nil }
        pendingInsert = nil
        return p.result
    }
}
