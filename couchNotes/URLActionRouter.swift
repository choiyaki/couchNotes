//
//  URLActionRouter.swift
//  couchNotes
//
//  URL スキーム（couchnotes://）の処理。
//  - couchnotes://open?path=Publish/会議メモ        … 既存ノートを開く（無ければエラー）
//  - couchnotes://new?path=Inbox/買い物&content=...  … 無ければ作成、あれば追記。常に開く
//  - couchnotes://append?path=20260606&text=...      … 常に作成 or 追記。常に開く
//  - couchnotes://handwrite[?path=Inbox/手書き]        … 手書きキャンバスを開く。完了で path（省略時は
//    今日の日付ノート yyyyMMdd）を作成 or 開き、末尾へ手書き画像を追記（iPhone/iPad のみ）
//  path はフルパス。スラッシュ有り＝フォルダ内、無し＝ルート直下。.md は任意。
//  open に限り、path がファイル名だけ（スラッシュ無し）の場合はフォルダ配下も含めて
//  ファイル名一致で検索する（例: open?path=20260617 で Publish/20260617.md を開く）。
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
        // 手書きはノート一覧の読み込みを待たずにキャンバスを出す（書き込み先は完了時に決める）
        if (url.host ?? "").lowercased() == "handwrite" {
            startHandwriting(url)
            return
        }
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

    // MARK: - 手書き

    private func startHandwriting(_ url: URL) {
        #if targetEnvironment(macCatalyst)
        errorMessage = "手書きメモは iPhone／iPad で使えます。"
        #else
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comps?.queryItems?.first { $0.name.lowercased() == "path" }?.value?
            .trimmingCharacters(in: .whitespaces)
        HandwritingInbox.shared.captureRequest = .init(path: (path?.isEmpty ?? true) ? nil : path)
        #endif
    }

    /// 手書きキャンバスの完了後: 書き込み先ノートを（無ければ空で作成して）開き、
    /// 末尾への挿入をノート画面（エディタ）へ託す。本文を直接書き換えないので、
    /// そのノートを編集中でも保存が衝突しない。
    func openForHandwriting(_ result: HandwritingResult, path: String?) async {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let target = resolve(path ?? df.string(from: Date()))
        let existing = await existingTarget(for: target)
        // ノート画面が開いた時（既に開いていれば即時）に拾えるよう、遷移より先に積む
        HandwritingInbox.shared.pendingInsert = .init(noteId: existing?.id ?? target.id, result: result)
        if let existing {
            noteToOpen = existing.id
        } else {
            await upsertAndOpen(target, text: "", addNewlineOnAppend: false)   // 空で作成して開く
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
        // 1) フルパス完全一致
        if await NoteStore.shared.editingNote(target.id) != nil {
            noteToOpen = target.id
            return
        }
        // 2) path がファイル名だけ（スラッシュ無し）なら、フォルダ配下も含め basename 一致で探す
        if !target.id.contains("/"),
           let found = await NoteStore.shared.findIDByBasename(target.id) {
            noteToOpen = found
            return
        }
        errorMessage = "ノートが見つかりません: \(target.path)"
    }

    /// 既存ノートの解決。URL が別フォルダを指定していても、同じタイトルがあれば既存の一意なノートを使う。
    private func existingTarget(for target: (id: String, path: String)) async -> (id: String, path: String)? {
        if let exact = await NoteStore.shared.editingNote(target.id) {
            return (target.id, exact.path ?? target.path)
        }
        if let existingID = await NoteStore.shared.findIDByTitle(target.path),
           let existing = await NoteStore.shared.editingNote(existingID) {
            return (existingID, existing.path ?? existingID)
        }
        return nil
    }

    /// 無ければ作成、あれば追記。完了後に開く。
    /// アプリ内作成と同じ「ローカルに dirty で保存 → SyncEngine が押し上げ」の書き込み経路を使う。
    /// サーバ直書き＋clean upsert だと、reconcile のサーバスナップショット（作成前に取得）との
    /// 競合で「サーバに無い clean 行」と誤判定され、ローカル行が削除される事故があった。
    /// dirty で書けば reconcile から保護され、オフラインでも作成・追記が成立する。
    private func upsertAndOpen(_ target: (id: String, path: String), text: String, addNewlineOnAppend: Bool) async {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let resolvedTarget = await existingTarget(for: target) ?? target
        let record: NoteRecord
        if let existing = await NoteStore.shared.editingNote(resolvedTarget.id) {
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
            record = NoteRecord(
                id: resolvedTarget.id, path: existing.path ?? resolvedTarget.path, mtime: nowMs, ctime: ctime,
                size: content.utf8.count, content: content
            )
        } else {
            // 新規作成
            let sec = Int(nowMs / 1000)
            let content = FrontmatterParser.compose(createdSec: sec, updatedSec: sec, extra: [], body: text)
            record = NoteRecord(
                id: resolvedTarget.id, path: resolvedTarget.path, mtime: nowMs, ctime: nowMs,
                size: content.utf8.count, content: content
            )
        }
        await NoteStore.shared.saveDirty(record)
        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        noteToOpen = resolvedTarget.id
        await SyncEngine.shared.flush()
    }
}
