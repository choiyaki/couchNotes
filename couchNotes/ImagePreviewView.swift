//
//  ImagePreviewView.swift
//  couchNotes
//
//  couchimg の画像のプレビュー画面（../couchimg/docs/DESIGN.md 4.3）。
//  画像（拡大縮小）・公開状態・OCR の文字（コピー・修正・端末ですぐ読む・ノートに貼る）・貼られているノート・削除。
//  OCR の文字はノートの本文には入れず、ここと検索で使う（D10）。
//

import SwiftUI
import UIKit

// MARK: - OCR の文字の取り込み（/api/changes → 端末の DB）

/// 画像内の文字を端末に取り込む。取り込んだ分は、オフラインでも検索できる。
@MainActor
enum ImageOCRSync {
    private static var lastRun: Date?
    private static var running = false

    /// 前回から1分たっていなければ何もしない（force で無視）。通信できないときは黙ってやめる（次の機会に続きから）。
    static func run(force: Bool = false) async {
        guard CouchImgService.hasAppToken, !running else { return }
        if !force, let last = lastRun, Date().timeIntervalSince(last) < 60 { return }
        running = true
        defer { running = false }
        for _ in 0..<200 {
            let position = await NoteStore.shared.ocrSyncPosition()
            guard let changes = try? await CouchImgService.changes(since: position.since, gen: position.gen) else { return }
            await NoteStore.shared.applyOCRChanges(changes)
            if !changes.more { break }
        }
        lastRun = Date()
    }
}

// MARK: - サムネイル（端末で作って端末に置く）

/// 画像一覧のサムネイル。サーバーには作らせず、端末で縮めて Caches に置く（バックアップ対象外・ロック中は読めない）。
actor CouchImgThumbnails {
    static let shared = CouchImgThumbnails()
    private let memory = NSCache<NSString, UIImage>()
    private var tasks: [String: Task<UIImage?, Never>] = [:]
    private static let maxPixel = 360

    private init() { memory.countLimit = 400 }

    private static var directory: URL {
        var dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("couchimg-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    private static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func image(id: String, ext: String) async -> UIImage? {
        if let hit = memory.object(forKey: id as NSString) { return hit }
        if let running = tasks[id] { return await running.value }
        let task = Task<UIImage?, Never> {
            let file = Self.directory.appendingPathComponent("\(id).jpg")
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
            let url = CouchImgService.baseURL.appendingPathComponent("\(id).\(ext)")
            guard let data = try? await CouchImgService.fetchImage(url).data, let thumb = Self.downsample(data) else { return nil }
            if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                try? jpeg.write(to: file, options: [.atomic, .completeFileProtection])
            }
            return thumb
        }
        tasks[id] = task
        let image = await task.value
        tasks[id] = nil
        if let image { memory.setObject(image, forKey: id as NSString) }
        return image
    }

    /// 削除した画像のサムネイルを消す
    func forget(id: String) {
        memory.removeObject(forKey: id as NSString)
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(id).jpg"))
    }
}

// MARK: - 拡大縮小できる画像

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

// MARK: - プレビュー画面

/// プレビュー画面で開く画像（sheet(item:) 用）
struct ImagePreviewTarget: Identifiable, Equatable {
    let id: String      // 画像 ID（32桁の16進）
    let ext: String

    init(id: String, ext: String) { self.id = id; self.ext = ext }

    /// ノートの本文の URL から。couchimg の画像でなければ nil
    init?(urlString: String) {
        guard let file = CouchImgService.imageFile(from: urlString) else { return nil }
        let parts = file.split(separator: ".")
        self.init(id: String(parts[0]), ext: String(parts[1]))
    }

    var url: URL { CouchImgService.baseURL.appendingPathComponent("\(id).\(ext)") }
}

struct ImagePreviewView: View {
    let target: ImagePreviewTarget
    /// 編集画面から開いたとき: 文字を ```ocr としてノートに貼る
    var onInsertOCR: ((String) -> Void)? = nil
    /// 画像一覧から開いたとき: 画像を開いているノートに貼る
    var onInsertImage: ((String) -> Void)? = nil
    /// 貼られているノートを開く（端末にあるノートだけ）
    var onOpenNote: ((String) -> Void)? = nil
    /// 公開・削除・文字の修正をした（呼び出し側の表示を更新する）
    var onChanged: ((Change) -> Void)? = nil

    enum Change { case published, deleted, ocrEdited }

    private enum Confirm: Identifiable { case publish, delete; var id: Int { hashValue } }
    private struct Conflict: Identifiable { let id = UUID(); let revision: Int; let serverText: String; let mine: String }

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var imageFailed = false
    @State private var info: CouchImgService.ImageInfo?
    @State private var infoError: String?
    @State private var offlineText: String?
    @State private var localNotes: Set<String> = []
    @State private var confirm: Confirm?
    @State private var message: String?
    @State private var isWorking = false
    @State private var editorDraft: String?
    @State private var conflict: Conflict?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    imageArea
                    if let info {
                        visibilitySection(info)
                        ocrSection(info)
                        notesSection(info)
                        footerSection(info)
                    } else if let infoError {
                        offlineSection(infoError)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .navigationTitle("画像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = target.url.absoluteString
                        flashCopied()
                    } label: { Label("URL をコピー", systemImage: copied ? "checkmark" : "link") }
                }
            }
        }
        .task { await load() }
        .task(id: info?.ocr.status) { await pollWhileReading() }
        .alert(confirm == .publish ? "この画像を公開しますか？" : "この画像をサーバーから削除しますか？",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { kind in
            Button(kind == .publish ? "公開する" : "削除する", role: .destructive) { Task { await perform(kind) } }
            Button("キャンセル", role: .cancel) {}
        } message: { kind in
            Text(kind == .publish
                 ? "公開すると、URL を知っている人は誰でも見られるようになります。公開は取り消せません（サーバーから削除することはできます）。上の画像に、見せたくないものが写っていないか確かめてください。"
                 : "サーバーから画像が消え、この URL では表示できなくなります。元に戻せません。ノートの本文は変わりません。")
        }
        .alert("画像", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .sheet(isPresented: Binding(get: { editorDraft != nil }, set: { if !$0 { editorDraft = nil } })) {
            OCREditorSheet(text: editorDraft ?? "") { text in
                editorDraft = nil
                Task { await save(text, base: info?.ocr.revision ?? 0) }
            }
        }
        .sheet(item: $conflict) { c in
            OCRConflictSheet(serverText: c.serverText, mine: c.mine) { useMine in
                conflict = nil
                if useMine { Task { await save(c.mine, base: c.revision) } } else { Task { await reloadInfo() } }
            }
        }
    }

    // MARK: 表示

    @ViewBuilder private var imageArea: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else if imageFailed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text("画像を表示できません").font(.footnote)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func visibilitySection(_ info: CouchImgService.ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(info.isPublic ? "公開中" : "非公開", systemImage: info.isPublic ? "globe" : "lock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(info.isPublic ? .orange : .secondary)
                Spacer()
                if !info.isPublic {
                    Button("公開する…") { confirm = .publish }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                }
            }
            if info.suggestPublish {
                hint("公開フォルダのノートに貼られていますが、この画像は非公開です。ブログなどに出すなら「公開する…」を押してください。",
                     systemImage: "exclamationmark.triangle", tint: .orange)
            } else if info.isPublic, !info.notes.isEmpty, !info.notes.contains(where: \.isPublic) {
                hint("公開中ですが、貼られているのは非公開のノートだけです。公開は取り消せないので、不要ならサーバーから削除できます。",
                     systemImage: "info.circle", tint: .secondary)
            }
        }
    }

    private func hint(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func ocrSection(_ info: CouchImgService.ImageInfo) -> some View {
        let ocr = info.ocr
        let text = ocr.text ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("画像内の文字").font(.subheadline.weight(.semibold))
                if ocr.edited { badge("修正済み") }
                if ocr.truncated { badge("途中で切れている可能性") }
                Spacer()
            }
            Text(statusText(ocr)).font(.footnote).foregroundStyle(.secondary)
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            // 横に並べると iPhone では収まらないので、折り返す
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ocrButtons(text) }
                VStack(alignment: .leading, spacing: 8) { ocrButtons(text) }
            }
        }
    }

    @ViewBuilder private func ocrButtons(_ text: String) -> some View {
        if !text.isEmpty {
            Button { UIPasteboard.general.string = text; flashCopied() } label: { Label("コピー", systemImage: "doc.on.doc") }
        }
        Button { editorDraft = text } label: { Label("修正", systemImage: "pencil") }
        Button { Task { await recognizeOnDevice() } } label: { Label("端末ですぐ読む", systemImage: "text.viewfinder") }
            .disabled(imageData == nil || isWorking)
        if let onInsertOCR, !text.isEmpty {
            Button { onInsertOCR(text); dismiss() } label: { Label("ノートに貼る", systemImage: "text.insert") }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(.tertiarySystemFill)).clipShape(Capsule())
    }

    private func statusText(_ ocr: CouchImgService.OCRInfo) -> String {
        switch ocr.status {
        case "pending":
            let minutes = max(1, ((ocr.queue?.etaSeconds ?? 240) + 59) / 60)
            let ahead = ocr.queue?.ahead ?? 0
            return ahead > 0 ? "読み取り待ち（前に \(ahead) 枚・あと約 \(minutes) 分）" : "読み取り待ち（あと約 \(minutes) 分）"
        case "running": return "サーバーで読み取り中（1枚 3〜4分）"
        case "failed": return "サーバーでの読み取りに失敗しました。「端末ですぐ読む」か「修正」で入れられます。"
        case "skipped": return "この形式（GIF・WebP）はサーバーでは読みません。「端末ですぐ読む」か「修正」で入れられます。"
        default: return (ocr.text ?? "").isEmpty ? "文字は見つかりませんでした。" : (ocr.edited ? "人が直した文字です。" : "サーバーの AI が読んだ文字です。")
        }
    }

    @ViewBuilder private func notesSection(_ info: CouchImgService.ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("貼られているノート").font(.subheadline.weight(.semibold))
            if info.notes.isEmpty {
                Text("どのノートにも貼られていません（貼ってから反映まで5分ほどかかります）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(info.notes) { note in
                let isLocal = localNotes.contains(note.docId)
                Button {
                    guard isLocal else { return }
                    dismiss()
                    onOpenNote?(note.docId)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: note.kind == "embed" ? "photo" : "link").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(noteTitle(note.path)).font(.callout).lineLimit(1)
                            Text(noteDetail(note, isLocal: isLocal)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if isLocal, onOpenNote != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isLocal ? 1 : 0.45)   // この端末に同期していないノートは薄く出す
                .disabled(!isLocal || onOpenNote == nil)
            }
        }
    }

    private func noteTitle(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    private func noteDetail(_ note: CouchImgService.NoteRef, isLocal: Bool) -> String {
        var parts: [String] = []
        let folder = note.path.split(separator: "/").dropLast().joined(separator: "/")
        if !folder.isEmpty { parts.append(folder) }
        if note.isPublic { parts.append("公開フォルダ") }
        if note.kind != "embed" { parts.append("リンクのみ") }
        if !isLocal { parts.append("この端末には未同期") }
        return parts.joined(separator: " ・ ")
    }

    @ViewBuilder private func footerSection(_ info: CouchImgService.ImageInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onInsertImage {
                Button { onInsertImage(info.url); dismiss() } label: { Label("開いているノートに貼る", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
            }
            Text(metaText(info)).font(.caption2).foregroundStyle(.secondary)
            Button(role: .destructive) { confirm = .delete } label: { Label("サーバーから削除…", systemImage: "trash") }
                .disabled(isWorking)
            Text("公開・削除は、WireGuard を繋いでいるときだけ使えます。").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func metaText(_ info: CouchImgService.ImageInfo) -> String {
        let date = Date(timeIntervalSince1970: info.createdAt).formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: Int64(info.bytes), countStyle: .file)
        return [date, "\(info.width)×\(info.height)", size, info.uploadedBy, info.uploadSource].compactMap { $0 }.joined(separator: " ・ ")
    }

    @ViewBuilder private func offlineSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
            if let offlineText, !offlineText.isEmpty {
                Text("画像内の文字（この端末に取り込み済みのもの）").font(.subheadline.weight(.semibold))
                Text(offlineText).font(.callout).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button("もう一度読み込む") { Task { await load() } }
        }
    }

    private func flashCopied() {
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
    }

    // MARK: 読み込みと操作

    private func load() async {
        async let loadedImage: Void = loadImage()
        await reloadInfo()
        await loadedImage
    }

    private func loadImage() async {
        guard image == nil else { return }
        if let result = try? await CouchImgService.fetchImage(target.url), let ui = UIImage(data: result.data) {
            imageData = result.data
            image = ui
        } else {
            imageFailed = true
        }
    }

    private func reloadInfo() async {
        do {
            let fresh = try await CouchImgService.imageInfo(id: target.id)
            localNotes = await NoteStore.shared.existingNoteIDs(fresh.notes.map(\.docId))
            info = fresh
            infoError = nil
        } catch {
            if info == nil {
                infoError = error.localizedDescription
                offlineText = await NoteStore.shared.ocrText(forImage: target.id)
            }
        }
    }

    /// サーバーが読み終えるまで、開いている間だけ15秒おきに確かめる
    private func pollWhileReading() async {
        while let status = info?.ocr.status, status == "pending" || status == "running" {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            await reloadInfo()
        }
    }

    private func perform(_ kind: Confirm) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch kind {
            case .publish:
                try await CouchImgService.publish(id: target.id)
                CouchImgSchemeHandler.forget(urlString: target.url.absoluteString)
                await reloadInfo()
                onChanged?(.published)
                message = "公開しました。"
            case .delete:
                try await CouchImgService.delete(id: target.id)
                CouchImgSchemeHandler.forget(urlString: target.url.absoluteString)
                await CouchImgThumbnails.shared.forget(id: target.id)
                onChanged?(.deleted)
                dismiss()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// 端末の Vision で読み、結果を修正の画面に入れる（保存を押すとサーバーに入る）
    private func recognizeOnDevice() async {
        guard let imageData else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let text = try await ImageTextRecognizer.visionText(from: imageData)
            if text.isEmpty { message = "画像から文字が見つかりませんでした。" } else { editorDraft = text }
        } catch {
            message = error.localizedDescription
        }
    }

    private func save(_ text: String, base: Int) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await CouchImgService.editOCR(id: target.id, text: text, baseRevision: base) {
            case .saved:
                await reloadInfo()
                onChanged?(.ocrEdited)
                await ImageOCRSync.run(force: true)
            case .conflict(let revision, let serverText):
                // 別の端末か AI が先に書き換えていた。両方を並べて選んでもらう
                conflict = Conflict(revision: revision, serverText: serverText ?? "", mine: text)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - 文字の修正

private struct OCREditorSheet: View {
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.callout)
                .padding(8)
                .navigationTitle("画像内の文字を修正")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(text) } }
                }
        }
    }
}

/// 保存しようとしたら、サーバーの文字が先に変わっていた。両方を見せて選んでもらう
private struct OCRConflictSheet: View {
    let serverText: String
    let mine: String
    let onChoose: (_ useMine: Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("保存する前に、サーバーの文字が別の端末（または AI の読み取り）で書き換わっていました。どちらを残すか選んでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                    column("サーバーの版", serverText)
                    column("自分の修正", mine)
                }
                .padding(16)
            }
            .navigationTitle("文字が食い違っています")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("サーバーの版を使う") { onChoose(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("自分の修正で上書き") { onChoose(true) } }
            }
        }
        .interactiveDismissDisabled()
    }

    private func column(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text.isEmpty ? "（空）" : text)
                .font(.callout).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
