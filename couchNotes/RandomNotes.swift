//
//  RandomNotes.swift
//  couchNotes
//
//  一覧に「今日のノート」をランダム表示する機能の状態管理。
//  ・除外フォルダ（この配下は抽選対象外）
//  ・その日の抽選結果（id×2）を日付つきで保存し、同日中は固定・日付が変われば選び直す
//  嫌になったら本ファイル／NoteListView の randomSection／設定の導線を消せば丸ごと外せる。
//

import Foundation

enum RandomNotes {
    /// 一覧に出す件数
    static let count = 2

    private static let excludeKey = "randomExcludedFolders"
    private static let picksKey   = "randomTodayPicks"   // 改行区切りの id
    private static let dateKey    = "randomTodayDate"    // "yyyy-MM-dd"

    // MARK: - 除外フォルダ

    /// 保存されている生の除外フォルダ
    static var excludedFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludeKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: excludeKey) }
    }

    /// 正規化・重複排除済み（大小は保持、判定は小文字）。正規化は SyncScope と共通。
    static var normalizedExcluded: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for f in excludedFolders {
            let n = SyncScope.normalize(f)
            guard !n.isEmpty, seen.insert(n.lowercased()).inserted else { continue }
            out.append(n)
        }
        return out
    }

    @discardableResult
    static func addExcluded(_ folder: String) -> String? {
        let n = SyncScope.normalize(folder)
        guard !n.isEmpty else { return nil }
        var cur = normalizedExcluded
        guard !cur.contains(where: { $0.lowercased() == n.lowercased() }) else { return nil }
        cur.append(n)
        excludedFolders = cur
        return n
    }

    @discardableResult
    static func removeExcluded(_ folder: String) -> Bool {
        let key = SyncScope.normalize(folder).lowercased()
        var cur = normalizedExcluded
        guard let i = cur.firstIndex(where: { $0.lowercased() == key }) else { return false }
        cur.remove(at: i)
        excludedFolders = cur
        return true
    }

    /// id が除外フォルダ配下か（小文字前方一致）。excludedLower は小文字化済みの除外リスト。
    static func isExcluded(_ id: String, excludedLower: [String]) -> Bool {
        let lid = id.lowercased()
        for f in excludedLower where lid.hasPrefix(f + "/") { return true }
        return false
    }

    // MARK: - その日の抽選

    private static var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 今日保存されているピック（日付が違えば空＝選び直し）
    private static var savedPicks: [String] {
        guard UserDefaults.standard.string(forKey: dateKey) == todayString else { return [] }
        return (UserDefaults.standard.string(forKey: picksKey) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids.joined(separator: "\n"), forKey: picksKey)
        UserDefaults.standard.set(todayString, forKey: dateKey)
    }

    /// 母集団（notes）から今日の表示分を解決する。
    /// 保存済みが今日のもので現在も有効ならそれを使い、無効・不足分は抽選して補い保存する。
    static func todaysPicks(from notes: [NoteItem]) -> [NoteItem] {
        let excluded = normalizedExcluded.map { $0.lowercased() }
        let pool = notes.filter { !isExcluded($0.id, excludedLower: excluded) }
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var chosen: [NoteItem] = []
        var used = Set<String>()
        for id in savedPicks {
            guard chosen.count < count, let item = byID[id], used.insert(id).inserted else { continue }
            chosen.append(item)
        }
        if chosen.count < count {
            for c in pool.shuffled() {
                guard chosen.count < count, used.insert(c.id).inserted else { continue }
                chosen.append(c)
            }
        }
        save(chosen.map { $0.id })
        return chosen
    }

    /// index の1枠だけ引き直す。今表示中のノート全部と重複しない新しい1件に差し替える。
    /// 候補が無ければ据え置き。
    static func reroll(_ current: [NoteItem], at index: Int, from notes: [NoteItem]) -> [NoteItem] {
        let excluded = normalizedExcluded.map { $0.lowercased() }
        let avoid = Set(current.map { $0.id })
        let pool = notes.filter { !isExcluded($0.id, excludedLower: excluded) && !avoid.contains($0.id) }
        guard let pick = pool.randomElement() else { return current }
        var updated = current
        if updated.indices.contains(index) { updated[index] = pick } else { updated.append(pick) }
        save(updated.map { $0.id })
        return updated
    }

    /// ローカルノートからトップレベルフォルダを導出（除外フォルダ設定の選択肢用）。
    static func localTopLevelFolders(from notes: [NoteItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for n in notes {
            let p = n.path ?? n.id
            guard let slash = p.firstIndex(of: "/") else { continue }
            let top = SyncScope.normalize(String(p[..<slash]))
            guard !top.isEmpty, seen.insert(top.lowercased()).inserted else { continue }
            out.append(top)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
