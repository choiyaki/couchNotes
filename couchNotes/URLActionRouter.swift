//
//  URLActionRouter.swift
//  couchNotes
//
//  URL スキーム（couchnotes://）の処理。
//  - couchnotes://open?path=Publish/会議メモ        … 既存ノートを開く（無ければエラー）
//  - couchnotes://new?path=Inbox/買い物&content=...  … 無ければ作成、あれば追記。常に開く
//  - couchnotes://append?path=20260606&text=...      … 常に作成 or 追記。常に開く
//  path はフルパス。スラッシュ有り＝フォルダ内、無し＝ルート直下。.md は任意。
//

import Foundation

@MainActor
final class URLActionRouter: ObservableObject {
    static let shared = URLActionRouter()
    private init() {}

    /// 開く対象の noteId（NoteListView が監視して遷移）
    @Published var noteToOpen: String? = nil
    /// エラーメッセージ（NoteListView が監視して表示）
    @Published var errorMessage: String? = nil

    private var pendingURL: URL?
    private var isReady = false

    /// onOpenURL から呼ぶ。準備前なら保留。
    func handle(_ url: URL) {
        pendingURL = url
        if isReady { processPending() }
    }

    /// NoteStore 準備・初回ロード後に呼ぶ。
    func markReady() {
        isReady = true
        processPending()
    }

    private func processPending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        Task { await process(url) }
    }

    // MARK: - 処理本体

    private func process(_ url: URL) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = (comps.host ?? "").lowercased()
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let v = item.value { params[item.name.lowercased()] = v }
        }
        guard let rawPath = params["path"], !rawPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "URL に path がありません。"
            return
        }
        let target = resolve(rawPath)

        switch action {
        case "open":
            await openNote(target)
        case "new":
            await upsertAndOpen(target, text: params["content"] ?? "", addNewlineOnAppend: true)
        case "append":
            let newline = (params["newline"]?.lowercased() ?? "true") != "false"
            await upsertAndOpen(target, text: params["text"] ?? "", addNewlineOnAppend: newline)
        default:
            errorMessage = "未対応のアクションです: \(action)"
        }
    }

    /// path パラメータから (_id, 表示パス) を作る。
    private func resolve(_ rawPath: String) -> (id: String, path: String) {
        var p = rawPath.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p.lowercased().hasSuffix(".md") { p = String(p.dropLast(3)) }
        let displayPath = p + ".md"
        return (displayPath.lowercased(), displayPath)
    }

    private func openNote(_ target: (id: String, path: String)) async {
        if await NoteStore.shared.editingNote(target.id) != nil {
            noteToOpen = target.id
        } else {
            errorMessage = "ノートが見つかりません: \(target.path)"
        }
    }

    /// 無ければ作成、あれば追記。完了後に開く。
    private func upsertAndOpen(_ target: (id: String, path: String), text: String, addNewlineOnAppend: Bool) async {
        let nowMs = Date().timeIntervalSince1970 * 1000
        do {
            if let existing = await NoteStore.shared.editingNote(target.id) {
                // 追記
                let body = existing.body
                let newBody = body
                    + ((addNewlineOnAppend && !body.isEmpty) ? "\n" : "")
                    + text
                let ctime = existing.ctime ?? nowMs
                let extra = (existing.extra ?? "").isEmpty ? [] : existing.extra!.components(separatedBy: "\n")
                let content = FrontmatterParser.compose(
                    createdSec: Int(ctime / 1000), updatedSec: Int(nowMs / 1000),
                    extra: extra, body: newBody
                )
                let path = existing.path ?? target.path
                try await CouchDBClient.shared.saveNoteContent(id: target.id, text: content)
                await NoteStore.shared.upsert(NoteRecord(
                    id: target.id, path: path, mtime: nowMs, ctime: ctime,
                    size: content.utf8.count, content: content
                ))
            } else {
                // 新規作成
                let sec = Int(nowMs / 1000)
                let content = FrontmatterParser.compose(createdSec: sec, updatedSec: sec, extra: [], body: text)
                try await CouchDBClient.shared.createNote(id: target.id, path: target.path, text: content)
                await NoteStore.shared.upsert(NoteRecord(
                    id: target.id, path: target.path, mtime: nowMs, ctime: nowMs,
                    size: content.utf8.count, content: content
                ))
            }
            NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
            noteToOpen = target.id
        } catch {
            errorMessage = "URL アクションに失敗しました\n\(error.localizedDescription)"
        }
    }
}
