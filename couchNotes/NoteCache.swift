//
//  NoteCache.swift
//  couchNotes
//
//  Created by 吉田篤史 on 2026/05/28.
//


import Foundation

/// ノート本文のインメモリキャッシュ
/// シングルトン。アプリ終了まで保持。
@MainActor
class NoteCache {
    static let shared = NoteCache()
    private init() {}

    private var cache: [String: String] = [:]

    // MARK: - 基本操作

    func get(_ id: String) -> String? {
        cache[id]
    }

    func set(_ id: String, content: String) {
        cache[id] = content
    }

    func has(_ id: String) -> Bool {
        cache[id] != nil
    }

    /// キャッシュ済みのノートID一覧（_changes でどれを優先更新するか判定に使う）
    var cachedIDs: Set<String> {
        Set(cache.keys)
    }
}
