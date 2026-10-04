//
//  ImageLibraryView.swift
//  couchNotes
//
//  couchimg の画像一覧（../couchimg/docs/DESIGN.md 4.5）。新しい順・OCR の文字で検索・絞り込み・整理のヒント。
//  - 単独で開いたとき: 画像を選ぶとプレビュー画面を開く
//  - 編集中に「画像を挿入」から開いたとき（onPick あり）: 画像を選ぶとカーソルの位置に貼る。長押しでプレビュー
//  書類スキャン（VisionKit）の画面もここに置く。
//

import SwiftUI
import VisionKit

struct ImageLibraryView: View {
    /// 編集中の「画像を挿入」: 選んだ画像の URL を返す
    var onPick: ((String) -> Void)? = nil
    /// 貼られているノートを開く
    var onOpenNote: ((String) -> Void)? = nil

    private enum Mode: String, CaseIterable, Identifiable {
        case all = "すべて", unattached = "貼っていない", hints = "整理のヒント"
        var id: String { rawValue }
    }
    private struct Cell: Identifiable, Equatable {
        let id: String
        let ext: String
        var isPublic: Bool?
        var notes: Int?
        var ocrStatus: String?
        var snippet: String?
        var url: String { CouchImgService.baseURL.appendingPathComponent("\(id).\(ext)").absoluteString }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .all
    @State private var query = ""
    @State private var source: String?
    @State private var cells: [Cell] = []
    @State private var next: String?
    @State private var hints: CouchImgService.Hints?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var preview: ImagePreviewTarget?
    @State private var loadGeneration = 0

    private static let sources: [(String, String)] = [
        ("couchnotes", "couchNotes"), ("couchlog", "couchLog"), ("share", "共有シート"), ("web", "Web ページ"), ("vscode", "VS Code"), ("import", "Gyazo から移行"),
    ]
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy にする: 末尾の「続きを読み込む」印が、そこまでスクロールしたときに初めて現れるように
                LazyVStack(alignment: .leading, spacing: 12) {
                    Picker("表示", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if mode == .hints {
                        hintsBody
                    } else {
                        grid(cells)
                        if next != nil {
                            // 続きの印（next）ごとに作り直す。作り直さないと .task が最初の1回しか走らず、
                            // 2ページ目（120枚）で読み込みが止まる
                            ProgressView().frame(maxWidth: .infinity).id(next).task { await loadMore() }
                        } else if cells.isEmpty, !isLoading, errorText == nil {
                            Text(query.isEmpty ? "画像はありません。" : "一致する画像はありません。")
                                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle(onPick == nil ? "画像" : "画像を挿入")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "画像内の文字で探す")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("どこから上げたか", selection: $source) {
                            Text("すべて").tag(String?.none)
                            ForEach(Self.sources, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                        }
                    } label: {
                        Image(systemName: source == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .disabled(mode == .hints)
                }
            }
            .overlay { if isLoading, cells.isEmpty, mode != .hints { ProgressView() } }
            .refreshable { await reload() }
        }
        .task(id: ReloadKey(mode: mode, query: query, source: source)) {
            // 入力中は少し待ってから探す
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            if Task.isCancelled { return }
            await reload()
        }
        .sheet(item: $preview) { target in
            ImagePreviewView(
                target: target,
                onInsertImage: onPick.map { pick in { url in pick(url); dismiss() } },
                onOpenNote: onOpenNote.map { open in { id in dismiss(); open(id) } },
                onChanged: { change in
                    if change == .deleted { cells.removeAll { $0.id == target.id } }
                    Task { await reload() }
                }
            )
        }
    }

    private struct ReloadKey: Equatable { let mode: Mode; let query: String; let source: String? }

    // MARK: 表示

    private func grid(_ items: [Cell]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(items) { cell in
                LibraryCellView(id: cell.id, ext: cell.ext, isPublic: cell.isPublic, notes: cell.notes,
                                ocrStatus: cell.ocrStatus, snippet: cell.snippet)
                    .onTapGesture {
                        if let onPick { onPick(cell.url); dismiss() } else { preview = ImagePreviewTarget(id: cell.id, ext: cell.ext) }
                    }
                    .onLongPressGesture { preview = ImagePreviewTarget(id: cell.id, ext: cell.ext) }
            }
        }
    }

    @ViewBuilder private var hintsBody: some View {
        if let hints {
            if hints.indexAt == nil {
                Text("ノートとの対応表がまだサーバーに届いていません。しばらくしてから開き直してください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            hintGroup("非公開なのに、公開フォルダのノートに貼ってある",
                      "ブログなどに出すなら、画像を開いて「公開する…」を押します。", hints.privateInPublicNotes)
            hintGroup("公開中なのに、非公開のノートにしか貼られていない",
                      "公開は取り消せません。不要なら、画像を開いてサーバーから削除できます。", hints.publicOnlyInPrivateNotes)
            hintGroup("どのノートにも貼られていない", "貼り忘れや、もう使っていない画像です。", hints.unattached)
            if hints.privateInPublicNotes.isEmpty, hints.publicOnlyInPrivateNotes.isEmpty, hints.unattached.isEmpty {
                Text("気になる画像はありません。").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
            }
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func hintGroup(_ title: String, _ detail: String, _ items: [CouchImgService.HintItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title)（\(items.count)）").font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                grid(items.compactMap { item in
                    ImagePreviewTarget(urlString: item.url).map { Cell(id: $0.id, ext: $0.ext) }
                })
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: 読み込み

    private var filter: CouchImgService.ImageFilter {
        .init(query: query, source: source, unattached: mode == .unattached)
    }

    private func cell(_ item: CouchImgService.ImageSummary) -> Cell {
        Cell(id: item.id, ext: item.ext, isPublic: item.isPublic, notes: item.notes, ocrStatus: item.ocrStatus, snippet: item.snippet)
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            if mode == .hints {
                let fresh = try await CouchImgService.hints()
                guard generation == loadGeneration else { return }
                hints = fresh
            } else {
                let list = try await CouchImgService.listImages(filter)
                guard generation == loadGeneration else { return }
                cells = list.items.map(cell)
                next = list.next
            }
            errorText = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorText = error.localizedDescription
            next = nil
        }
    }

    private func loadMore() async {
        guard let before = next, !isLoading else { return }
        let generation = loadGeneration
        do {
            let list = try await CouchImgService.listImages(filter, before: before)
            guard generation == loadGeneration else { return }
            let known = Set(cells.map(\.id))
            cells.append(contentsOf: list.items.map(cell).filter { !known.contains($0.id) })
            next = list.next
        } catch {
            guard generation == loadGeneration else { return }
            next = nil
            errorText = error.localizedDescription
        }
    }
}

/// 一覧の1マス。サムネイルと、状態の小さな印（公開・貼っていない・読み取り待ち）
private struct LibraryCellView: View {
    let id: String
    let ext: String
    let isPublic: Bool?
    let notes: Int?
    let ocrStatus: String?
    let snippet: String?
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if isPublic == true { mark("globe", .orange) }
                        if notes == 0 { mark("questionmark.folder", .gray) }
                        if ocrStatus == "pending" || ocrStatus == "running" { mark("hourglass", .blue) }
                    }
                    .padding(4)
                }
                .overlay {
                    if isPublic == true { RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2) }
                }
            if let snippet, !snippet.isEmpty {
                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .task(id: id) { image = await CouchImgThumbnails.shared.image(id: id, ext: ext) }
    }

    private func mark(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(color.opacity(0.85))
            .clipShape(Circle())
    }
}

// MARK: - 書類スキャン

/// 書類スキャン（VisionKit）。複数ページを1ページ1枚の画像として返す（DESIGN.md 5章 2-5 d）
struct DocumentScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // 画面を閉じるのは呼び出し側（SwiftUI の状態）に任せる
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}
