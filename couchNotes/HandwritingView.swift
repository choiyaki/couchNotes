//
//  HandwritingView.swift
//  couchNotes
//
//  手書きメモのキャンバス（PencilKit 純正キャンバス＋ツールパレット）。
//  完了で PNG を書き出して Gyazo へアップロードし、成功したら URL を呼び出し元へ返して閉じる。
//  失敗時は閉じずに「再試行」できる（手書きは貼り直しができないので、描いた内容を失わせない）。
//  写真アプリにも保存できる（アップロードできない時に残しておき、後で写真ボタンから貼れるように）。
//  背景（無地・方眼・罫線・ドット）と OCR のオン/オフは次回も引き継ぐ。
//

import SwiftUI
import PencilKit
import Photos

/// 手書きメモのアップロード結果
struct HandwritingResult {
    let url: String
    /// OCR 有効時の Vision 用画像（白地＋線だけ）。nil なら OCR しない
    let ocrImage: Data?
}

struct HandwritingView: View {
    /// 貼り先のノートのパス（couchimg へのアップロードに手がかりとして添える。分からなければ nil）
    var notePath: String? = nil
    var onComplete: (HandwritingResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("handwritingPaper") private var paperRaw = PaperStyle.grid.rawValue
    @AppStorage("handwritingOCR") private var ocrEnabled = true
    @StateObject private var model = HandwritingModel()
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var confirmDiscard = false
    @State private var isSavingPhoto = false
    @State private var photoMessage: String?

    private var paper: PaperStyle { PaperStyle(rawValue: paperRaw) ?? .grid }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HandwritingCanvas(model: model, paper: paper)
                // キャンバスは透明。スクロールで端を越えた時も紙の白を見せる
                .background(Color(uiColor: PaperStyle.paperColor))
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(.systemBackground))
        .overlay {
            if isUploading {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("アップロード中…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("アップロードに失敗しました", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("再試行") { Task { await finish() } }
            Button("写真に保存して閉じる") { Task { await saveToPhotos(thenClose: true) } }
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(uploadError ?? "")
        }
        .alert("手書きを破棄しますか？", isPresented: $confirmDiscard) {
            Button("写真に保存して閉じる") { Task { await saveToPhotos(thenClose: true) } }
            Button("破棄", role: .destructive) { dismiss() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(photoMessage ?? "", isPresented: Binding(
            get: { photoMessage != nil },
            set: { if !$0 { photoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("キャンセル") {
                    if model.hasDrawing { confirmDiscard = true } else { dismiss() }
                }
                Spacer()
                Button {
                    Task { await saveToPhotos(thenClose: false) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!model.hasDrawing || isSavingPhoto)
                .accessibilityLabel("写真に保存")
                Toggle(isOn: $ocrEnabled) {
                    Label("OCR", systemImage: "text.viewfinder")
                }
                .toggleStyle(.button)
                Spacer()
                Button {
                    Task { await finish() }
                } label: {
                    Text("完了").bold()
                }
                .disabled(!model.hasDrawing || isUploading)
            }
            Picker("背景", selection: $paperRaw) {
                ForEach(PaperStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Gyazo へ上げるのと同じ PNG（白い紙＋模様＋線）を写真アプリへ保存する（追加のみの権限）。
    @MainActor
    private func saveToPhotos(thenClose: Bool) async {
        guard !isSavingPhoto, let canvas = model.canvas,
              let output = HandwritingExporter.export(drawing: canvas.drawing,
                                                      width: canvas.bounds.width,
                                                      paper: paper) else { return }
        isSavingPhoto = true
        defer { isSavingPhoto = false }
        do {
            try await PhotoLibrarySaver.savePNG(output.png)
            if thenClose { dismiss() } else { photoMessage = "写真に保存しました" }
        } catch {
            photoMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finish() async {
        guard !isUploading, let canvas = model.canvas,
              let output = HandwritingExporter.export(drawing: canvas.drawing,
                                                      width: canvas.bounds.width,
                                                      paper: paper) else { return }
        if let message = ImageUploader.notReadyMessage() {
            uploadError = message
            return
        }
        isUploading = true
        defer { isUploading = false }
        do {
            let url = try await ImageUploader.upload(
                imageData: output.png, filename: "handwriting.png", mimeType: "image/png", notePath: notePath)
            onComplete(HandwritingResult(url: url, ocrImage: ocrEnabled ? output.ocrImage : nil))
            dismiss()
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

// MARK: - 写真アプリへの保存

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "写真へのアクセスが許可されていません。設定アプリ → couchNotes →「写真」で「写真を追加のみ」以上を許可してください。"
        }
    }

    static func savePNG(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

// MARK: - キャンバス

@MainActor
final class HandwritingModel: ObservableObject {
    weak var canvas: PaperCanvasView?
    @Published var hasDrawing = false
}

/// 紙の模様を最背面に敷いた PKCanvasView。描いた位置に合わせて縦に伸びる。
final class PaperCanvasView: PKCanvasView {
    private let paperView = UIView()

    var paper: PaperStyle = .grid {
        didSet { if paper != oldValue { paperView.backgroundColor = paper.patternColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 紙は常に白なので、インク色（ダークモードで反転する）もライト外観で扱う
        overrideUserInterfaceStyle = .light
        // 線を描く内部ビューはキャンバスの背景色を受け継いで不透明に塗るため、
        // 背景を透明にしておかないと奥の模様（paperView）が隠れる。紙の白は paperView が塗る。
        backgroundColor = .clear
        isOpaque = false
        drawingPolicy = .anyInput   // iPhone では指で描く
        alwaysBounceVertical = true
        paperView.isUserInteractionEnabled = false
        paperView.backgroundColor = paper.patternColor
        insertSubview(paperView, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // ツールパレットは first responder のときに出る
        if window != nil { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 画面 1 枚ぶん＋描いた一番下から半画面ぶんの余白まで伸ばす（縮めはしない）
        let drawn = drawing.bounds
        let needed = max(bounds.height, drawn.isEmpty ? 0 : drawn.maxY + bounds.height / 2)
        let height = max(contentSize.height, needed)
        if contentSize.width != bounds.width || contentSize.height != height {
            contentSize = CGSize(width: bounds.width, height: height)
        }
        // 模様の原点を (0,0) に保つ（書き出し画像と線の位置を一致させる）
        paperView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                 height: max(height, contentOffset.y + bounds.height))
        sendSubviewToBack(paperView)
    }
}

struct HandwritingCanvas: UIViewRepresentable {
    let model: HandwritingModel
    var paper: PaperStyle

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PaperCanvasView {
        let canvas = PaperCanvasView(frame: .zero)
        canvas.paper = paper
        canvas.delegate = context.coordinator
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        model.canvas = canvas

        let picker = PKToolPicker()
        picker.colorUserInterfaceStyle = .light
        picker.stateAutosaveName = "couchNotesHandwriting"   // 前回のペン・色を覚える
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker = picker
        return canvas
    }

    func updateUIView(_ canvas: PaperCanvasView, context: Context) {
        canvas.paper = paper
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let model: HandwritingModel
        var toolPicker: PKToolPicker?   // 保持しないとパレットが消える

        init(model: HandwritingModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let has = !canvasView.drawing.strokes.isEmpty
            Task { @MainActor in if model.hasDrawing != has { model.hasDrawing = has } }
            canvasView.setNeedsLayout()   // 描いた位置に合わせて縦に伸ばす
        }
    }
}
