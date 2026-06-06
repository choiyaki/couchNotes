//
//  FrontmatterMigration.swift
//  couchNotes
//
//  全ノートに created/updated（YAML）を付与する一回限りの移行。
//  - 既に YAML created/updated があるノート → YAML を正として ctime/mtime に反映
//  - 無いノート → ctime/mtime から YAML を本文に付与（時刻は据え置き）
//

import Foundation

enum FrontmatterMigration {
    static let doneKey = "yaml_migration_v1"

    static func isDone() async -> Bool {
        await NoteStore.shared.syncValue(doneKey) == "done"
    }

    /// 移行を実行。progress は 0...1。
    static func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        // 同期範囲の全ノートを本文込みで取得
        let records = try await CouchDBClient.shared.fetchScopedNotes(
            folders: SyncScope.normalizedFolders, includeRoot: true
        )
        let total = max(records.count, 1)

        for (i, r) in records.enumerated() {
            let parsed = FrontmatterParser.split(r.content)

            if parsed.created != nil || parsed.updated != nil {
                // YAML を正 → ctime/mtime に反映（秒→ms）
                let fallbackCtime = r.ctime ?? r.mtime ?? Date().timeIntervalSince1970 * 1000
                let fallbackMtime = r.mtime ?? fallbackCtime
                let ctime = parsed.created.map { Double($0) * 1000 } ?? fallbackCtime
                let mtime = parsed.updated.map { Double($0) * 1000 } ?? fallbackMtime
                try? await CouchDBClient.shared.updateNoteTimes(id: r.id, ctime: ctime, mtime: mtime)
                await NoteStore.shared.upsert(NoteRecord(
                    id: r.id, path: r.path, mtime: mtime, ctime: ctime,
                    size: r.size, content: r.content
                ))
            } else {
                // YAML 無し → メタデータから付与（時刻は据え置き）
                let ctime = r.ctime ?? r.mtime ?? Date().timeIntervalSince1970 * 1000
                let mtime = r.mtime ?? ctime
                let newContent = FrontmatterParser.compose(
                    createdSec: Int(ctime / 1000),
                    updatedSec: Int(mtime / 1000),
                    extra: parsed.extraLines,
                    body: parsed.body
                )
                try? await CouchDBClient.shared.saveContentPreservingTimes(
                    id: r.id, text: newContent, ctime: ctime, mtime: mtime
                )
                await NoteStore.shared.upsert(NoteRecord(
                    id: r.id, path: r.path, mtime: mtime, ctime: ctime,
                    size: newContent.utf8.count, content: newContent
                ))
            }

            progress(Double(i + 1) / Double(total))
        }

        await NoteStore.shared.setSyncValue(doneKey, "done")
    }
}
