//
//  RenameService.swift
//  couchNotes
//
//  ノートのタイトル（ファイル名）変更。フォルダは変えず _id/path のファイル名部分のみ変更し、
//  他ノートの [[wikiリンク]] も書き換える。
//  CouchDB は _id=パスのため「新ID作成＋旧ID削除」で行う（本文・created は保持、updated は now）。
//

import Foundation

enum RenameError: LocalizedError {
    case emptyTitle
    case unchanged
    case sourceMissing
    case duplicate

    var errorDescription: String? {
        switch self {
        case .emptyTitle:    return "タイトルが空です。"
        case .unchanged:     return "タイトルが変わっていません。"
        case .sourceMissing: return "元のノートが見つかりません。"
        case .duplicate:     return "同じ場所に同名のノートが既に存在します。"
        }
    }
}

@MainActor
enum RenameService {
    /// タイトル変更を実行し、新しい noteId を返す。
    static func rename(oldId: String, oldPath: String?, newTitle: String) async throws -> String {
        let safe = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !safe.isEmpty else { throw RenameError.emptyTitle }

        // 新しい _id（フォルダ部は小文字のまま、ファイル名は小文字）と path（フォルダ原文＋新タイトル）
        let idFolder = oldId.components(separatedBy: "/").dropLast()
        let newId = (idFolder + [safe.lowercased() + ".md"]).joined(separator: "/")
        guard newId != oldId else { throw RenameError.unchanged }

        let pathSource = oldPath ?? oldId
        let pathFolder = pathSource.components(separatedBy: "/").dropLast()
        let newPath = (pathFolder + [safe + ".md"]).joined(separator: "/")

        // 衝突チェック（ローカル）
        if await NoteStore.shared.editingNote(newId) != nil { throw RenameError.duplicate }

        // 旧ノート本体（フロントマター除去済み body・ctime・extra）
        guard let stored = await NoteStore.shared.editingNote(oldId) else { throw RenameError.sourceMissing }

        // 旧リンクキー（小文字・.md 除去）
        let oldLower = oldId.lowercased().hasSuffix(".md") ? String(oldId.lowercased().dropLast(3)) : oldId.lowercased()
        let oldFullKey = oldLower
        let oldBaseKey = oldLower.components(separatedBy: "/").last ?? oldLower

        // 先に被リンク元を集める（本体削除の影響を受けないよう前もって）
        let sources = await NoteStore.shared.backlinks(for: oldId)

        let nowMs  = Date().timeIntervalSince1970 * 1000
        let ctime  = stored.ctime ?? nowMs
        let extra  = (stored.extra ?? "").isEmpty ? [] : stored.extra!.components(separatedBy: "\n")
        let content = FrontmatterParser.compose(
            createdSec: Int(ctime / 1000), updatedSec: Int(nowMs / 1000),
            extra: extra, body: stored.body
        )

        // 1) 本体リネーム（新ID作成 → 旧ID削除）
        try await CouchDBClient.shared.putNoteContent(
            id: newId, path: newPath, text: content,
            ctime: ctime, mtime: nowMs, requireAbsent: true
        )
        try await CouchDBClient.shared.deleteNote(id: oldId)
        await NoteStore.shared.upsert(NoteRecord(
            id: newId, path: newPath, mtime: nowMs, ctime: ctime,
            size: content.utf8.count, content: content
        ))
        await NoteStore.shared.delete(oldId)

        // 2) 被リンク元の [[...]] を書き換えて保存
        for src in sources {
            guard src.id != oldId, let s = await NoteStore.shared.editingNote(src.id) else { continue }
            let rewritten = rewriteLinks(in: s.body, oldFullKey: oldFullKey, oldBaseKey: oldBaseKey, newTitle: safe)
            guard rewritten != s.body else { continue }
            let sctime  = s.ctime ?? nowMs
            let sextra  = (s.extra ?? "").isEmpty ? [] : s.extra!.components(separatedBy: "\n")
            let sContent = FrontmatterParser.compose(
                createdSec: Int(sctime / 1000), updatedSec: Int(nowMs / 1000),
                extra: sextra, body: rewritten
            )
            do {
                try await CouchDBClient.shared.saveNoteContent(id: src.id, text: sContent)
                await NoteStore.shared.upsert(NoteRecord(
                    id: src.id, path: src.path, mtime: nowMs, ctime: sctime,
                    size: sContent.utf8.count, content: sContent
                ))
            } catch {
                // 個別の失敗は無視して続行
            }
        }

        NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)
        return newId
    }

    // MARK: - リンク書き換え

    private static let linkRegex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)

    /// body 内の [[...]] のうち旧ノートに解決されるものを新タイトルへ書き換える。
    static func rewriteLinks(in body: String, oldFullKey: String, oldBaseKey: String, newTitle: String) -> String {
        guard let regex = linkRegex else { return body }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return body }

        let result = NSMutableString(string: body)
        // 後ろから置換してレンジを保つ
        for m in matches.reversed() {
            let inner = ns.substring(with: m.range(at: 1))
            guard let newInner = rewriteInner(inner, oldFullKey: oldFullKey, oldBaseKey: oldBaseKey, newTitle: newTitle)
            else { continue }
            result.replaceCharacters(in: m.range, with: "[[" + newInner + "]]")
        }
        return result as String
    }

    /// `[[ inner ]]` の inner を必要なら書き換える。対象外なら nil。
    private static func rewriteInner(_ inner: String, oldFullKey: String, oldBaseKey: String, newTitle: String) -> String? {
        // エイリアス（|）と見出し（#）を分離して保持
        var target = inner
        var aliasSuffix = ""
        if let bar = inner.firstIndex(of: "|") {
            target = String(inner[..<bar])
            aliasSuffix = String(inner[bar...])       // "|..." を保持
        }
        var core = target
        var headingSuffix = ""
        if let hash = target.firstIndex(of: "#") {
            core = String(target[..<hash])
            headingSuffix = String(target[hash...])   // "#..." を保持
        }

        let coreTrim = core.trimmingCharacters(in: .whitespaces)
        guard !coreTrim.isEmpty else { return nil }
        let hadMd = coreTrim.lowercased().hasSuffix(".md")
        var keyCore = coreTrim.lowercased()
        if hadMd { keyCore = String(keyCore.dropLast(3)) }

        if keyCore == oldFullKey {
            // フルパス表記 → 末尾要素のみ新タイトルへ（フォルダ表記は維持）
            var comps = coreTrim.components(separatedBy: "/")
            comps[comps.count - 1] = newTitle + (hadMd ? ".md" : "")
            return comps.joined(separator: "/") + headingSuffix + aliasSuffix
        } else if !coreTrim.contains("/"),
                  (keyCore.components(separatedBy: "/").last ?? keyCore) == oldBaseKey {
            // ファイル名のみ表記
            return newTitle + (hadMd ? ".md" : "") + headingSuffix + aliasSuffix
        }
        return nil
    }
}
