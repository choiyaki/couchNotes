//
//  PinService.swift
//  couchNotes
//
//  一覧のピン留め。フロントマターに pin: N を持たせ、番号が小さいほど上位表示。
//  外すと、それより大きい番号を持つ全ノートの番号を1つずつ繰り上げる。
//  ピン操作自体は「メタ情報の付け外し」なので created/updated（＝一覧の日時表示）は変更しない。
//

import Foundation

@MainActor
enum PinService {
    /// 未ピンのノートをピン留めする（既存の最大番号+1を採番）。
    static func pin(_ id: String) async {
        guard let stored = await NoteStore.shared.editingNote(id) else { return }
        let extra = extraLines(of: stored)
        guard FrontmatterParser.extractPin(from: extra) == nil else { return }   // 既にピン留め済み

        let next = (await NoteStore.shared.maxPin() ?? 0) + 1
        await save(id: id, stored: stored, extra: FrontmatterParser.withPin(next, in: extra))
        await SyncEngine.shared.flush()
    }

    /// ピン留めを外し、後続の番号を繰り上げる。
    static func unpin(_ id: String) async {
        guard let stored = await NoteStore.shared.editingNote(id) else { return }
        let extra = extraLines(of: stored)
        guard let removedPin = FrontmatterParser.extractPin(from: extra) else { return }

        await save(id: id, stored: stored, extra: FrontmatterParser.withPin(nil, in: extra))

        for entry in await NoteStore.shared.pinnedIDs() where entry.pin > removedPin {
            guard let s = await NoteStore.shared.editingNote(entry.id) else { continue }
            let sExtra = extraLines(of: s)
            await save(id: entry.id, stored: s, extra: FrontmatterParser.withPin(entry.pin - 1, in: sExtra))
        }

        await SyncEngine.shared.flush()
    }

    private static func extraLines(of stored: StoredNote) -> [String] {
        (stored.extra ?? "").isEmpty ? [] : stored.extra!.components(separatedBy: "\n")
    }

    /// 本文・created・updated はそのまま維持し、extra だけ差し替えて dirty 保存する。
    private static func save(id: String, stored: StoredNote, extra: [String]) async {
        let content = FrontmatterParser.compose(
            createdSec: stored.ctime.map { Int($0 / 1000) },
            updatedSec: stored.mtime.map { Int($0 / 1000) },
            extra: extra, body: stored.body
        )
        await NoteStore.shared.saveDirty(NoteRecord(
            id: id, path: stored.path ?? id,
            mtime: stored.mtime, ctime: stored.ctime,
            size: content.utf8.count, content: content
        ))
    }
}
