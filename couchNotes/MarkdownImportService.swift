//
//  MarkdownImportService.swift
//  couchNotes
//
//  端末（Files / iCloud Drive）のフォルダから .md を一括取り込みする。
//  選んだフォルダ名をそのまま couchNotes のトップフォルダ名として使い、配下の相対パスを保つ。
//  日時はフロントマター（created/updated）優先、無ければファイルの作成/更新日時で補完する。
//

import Foundation

struct MarkdownImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MarkdownImportService {

    /// 選択フォルダ配下の全 .md を読み込み、(path, content) を作る。
    /// - path は「選んだフォルダ名 + "/" + 配下の相対パス」。
    /// - progress は 0...1（読み込み進捗）。
    /// 戻り値の rootFolder は同期範囲に追加するフォルダ名。
    /// 並列読み込みの同時実行数。iCloud の未ダウンロードファイルを並行して取得するため。
    private static let maxConcurrentReads = 8

    static func loadFiles(
        from folderURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (rootFolder: String, files: [(path: String, content: String)]) {
        let rootName = folderURL.lastPathComponent
        guard !rootName.isEmpty else {
            throw MarkdownImportError(message: "フォルダ名を取得できませんでした。")
        }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]   // .obsidian / .git などの隠しフォルダは除外
        ) else {
            throw MarkdownImportError(message: "フォルダを読み込めませんでした。")
        }

        // 進捗計算のため、まず対象 URL を集める
        var mdURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            mdURLs.append(url)
        }
        guard !mdURLs.isEmpty else {
            throw MarkdownImportError(message: "選んだフォルダに .md ファイルがありません。")
        }

        let basePath = folderURL.standardizedFileURL.path
        let total = mdURLs.count

        // 同時実行数を制限した TaskGroup で並列読み込み。完了順に進捗を更新し、
        // 結果は元の順序を保つよう index 付きで集めて最後に並べ直す。
        let counter = ProgressCounter()
        var indexed: [(Int, (path: String, content: String))] = []
        indexed.reserveCapacity(total)

        try await withThrowingTaskGroup(of: (Int, (path: String, content: String)?).self) { group in
            func addTask(_ i: Int) {
                let url = mdURLs[i]
                group.addTask {
                    let item = readOne(url: url, basePath: basePath, rootName: rootName)
                    let done = await counter.increment()
                    progress(Double(done) / Double(total))
                    return (i, item)
                }
            }

            var next = 0
            while next < min(maxConcurrentReads, total) {
                addTask(next); next += 1
            }
            while let (idx, item) = try await group.next() {
                if let item { indexed.append((idx, item)) }
                if next < total { addTask(next); next += 1 }
            }
        }

        let result = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        guard !result.isEmpty else {
            throw MarkdownImportError(message: "読み込めるノートがありませんでした（UTF-8 のみ対応）。")
        }
        return (rootName, result)
    }

    /// 1ファイルを読み込んで (repoPath, content) を作る。読めなければ nil。
    private static func readOne(url: URL, basePath: String, rootName: String) -> (path: String, content: String)? {
        // UTF-8 で読めないものはスキップ
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // 選んだフォルダからの相対パス
        let full = url.standardizedFileURL.path
        var rel = full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : url.lastPathComponent
        if rel.hasPrefix("/") { rel.removeFirst() }
        guard !rel.isEmpty else { return nil }

        let repoPath = rootName + "/" + rel
        let content = fillTimesIfNeeded(text, url: url)
        return (repoPath, content)
    }

    /// フロントマターに created/updated が欠けていれば、ファイル日時で補ってアプリ形式に再合成する。
    private static func fillTimesIfNeeded(_ text: String, url: URL) -> String {
        let parsed = FrontmatterParser.split(text)
        if parsed.created != nil && parsed.updated != nil { return text }   // 既に揃っていればそのまま

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modSec    = values?.contentModificationDate.map { Int($0.timeIntervalSince1970) }
        let createSec = values?.creationDate.map { Int($0.timeIntervalSince1970) }
        let nowSec    = Int(Date().timeIntervalSince1970)

        let createdSec = parsed.created ?? createSec ?? modSec ?? nowSec
        let updatedSec = parsed.updated ?? modSec ?? createdSec

        return FrontmatterParser.compose(
            createdSec: createdSec, updatedSec: updatedSec,
            extra: parsed.extraLines, body: parsed.body
        )
    }
}

/// 並列読み込みの完了件数を安全に数えるためのカウンタ。
private actor ProgressCounter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
