//
//  SyncLog.swift
//  couchNotes
//
//  同期の所要時間を診断するためのロガー。
//  Console.app / Xcode コンソールで subsystem:"couchNotes" category:"sync" で絞り込める。
//  .debug/.info レベルなので通常運用のコストはごく小さい。
//

import Foundation
import os

/// 同期計測用の共有ロガー。
let syncLog = Logger(subsystem: "couchNotes", category: "sync")

/// 経過ミリ秒を測るための軽量ヘルパ。
struct SyncTimer {
    private let start = ContinuousClock.now

    /// 開始からの経過ミリ秒（整数）。
    var elapsedMs: Int {
        let c = start.duration(to: .now).components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
