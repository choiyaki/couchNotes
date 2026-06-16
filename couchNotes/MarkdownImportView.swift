//
//  MarkdownImportView.swift
//  couchNotes
//
//  フォルダを選んで配下の .md を一括取り込みする設定画面。
//  読み込み（端末）→ CouchDB へ一括書き戻し（上書き＋追記）→ ローカル反映、の2フェーズ。
//

import SwiftUI
import UniformTypeIdentifiers

struct MarkdownImportView: View {
    @State private var showPicker = false
    @State private var running = false
    @State private var phase = ""
    @State private var progress = 0.0
    @State private var resultMessage: String?

    var body: some View {
        Form {
            Section(footer: Text("選んだフォルダ配下の .md を取り込みます。フォルダ名がそのまま couchNotes のフォルダになり、同期範囲に追加されます。同名のノートは上書き、無いものは追加します（ローカルにしかないノートは削除しません）。")) {
                Button {
                    showPicker = true
                } label: {
                    Label("フォルダを選んで取り込む", systemImage: "folder.badge.plus")
                }
                .disabled(running)
            }

            if running {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(phase)… \(Int(progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: progress)
                    }
                }
            }
        }
        .navigationTitle("md 取り込み")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):  Task { await runImport(url) }
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
        .alert("取り込み", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func runImport(_ url: URL) async {
        running = true
        progress = 0
        phase = "読み込み中"
        defer { running = false }

        // フォルダはセキュリティスコープ付き。ファイル読み込み中だけアクセスを開く。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            // 1) 読み込み（メインスレッドを塞がないよう別スレッドで）
            let loaded = try await Task.detached(priority: .userInitiated) {
                try await MarkdownImportService.loadFiles(from: url) { p in
                    Task { @MainActor in progress = p * 0.5 }
                }
            }.value

            // 2) 同期範囲にフォルダを追加（通知は出さない＝余計なバックフィル取得を避ける）
            SyncScope.add(loaded.rootFolder)

            // 3) CouchDB へ一括書き戻し
            phase = "書き込み中"
            let written = try await CouchDBClient.shared.restore(files: loaded.files) { p in
                Task { @MainActor in progress = 0.5 + p * 0.5 }
            }

            // 4) ローカル（SQLite）へ即時反映し、一覧を更新
            let records = loaded.files.map { f -> NoteRecord in
                let parsed = FrontmatterParser.split(f.content)
                return NoteRecord(
                    id: f.path.lowercased(),
                    path: f.path,
                    mtime: parsed.updated.map { Double($0) * 1000 },
                    ctime: parsed.created.map { Double($0) * 1000 },
                    size: f.content.utf8.count,
                    content: f.content
                )
            }
            await NoteStore.shared.upsertMany(records)
            NotificationCenter.default.post(name: .noteStoreDidChange, object: nil)

            resultMessage = "取り込み完了（\(written) 件）\nフォルダ「\(loaded.rootFolder)」を同期範囲に追加しました。"
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}
