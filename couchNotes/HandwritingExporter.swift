//
//  HandwritingExporter.swift
//  couchNotes
//
//  手書きメモの紙（背景）と画像書き出し。
//  - 紙は常に白。模様（方眼・罫線・ドット）は原点 (0,0) 基準で「マスの中央」に線・点を置く。
//    キャンバス上は 1 マスのタイル画像を敷き詰め（縦に長くても巨大なビットマップを作らない）、
//    書き出しは同じ位置に直接描くので、両者で線の位置が一致する。
//  - 書き出しは横幅＝キャンバス幅で固定、縦は描いた一番下＋余白で切る。
//  - OCR 用には模様なし（白地＋線だけ）の画像も作る（Gyazo が使えない時の Vision 用）。
//

import UIKit
import PencilKit

enum PaperStyle: String, CaseIterable, Identifiable {
    case plain, grid, ruled, dots

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "無地"
        case .grid:  return "方眼"
        case .ruled: return "罫線"
        case .dots:  return "ドット"
        }
    }

    static let paperColor = UIColor.white
    private static let lineColor = UIColor(white: 0.86, alpha: 1)
    private static let dotColor  = UIColor(white: 0.72, alpha: 1)

    /// 模様の間隔（pt）
    private var spacing: CGFloat {
        switch self {
        case .plain: return 0
        case .grid, .dots: return 24
        case .ruled: return 32
        }
    }

    /// キャンバス背景用: 1 マスのタイルを敷き詰める色（無地は白）
    var patternColor: UIColor {
        guard self != .plain else { return Self.paperColor }
        let cell = CGRect(x: 0, y: 0, width: spacing, height: spacing)
        let tile = UIGraphicsImageRenderer(size: cell.size).image { ctx in
            Self.paperColor.setFill()
            ctx.fill(cell)
            drawPattern(in: cell, context: ctx.cgContext)
        }
        return UIColor(patternImage: tile)
    }

    /// rect の範囲に模様を描く（紙の塗りは含まない）。線・点は原点基準で各マスの中央（k*間隔 + 間隔/2）。
    func drawPattern(in rect: CGRect, context: CGContext) {
        guard self != .plain else { return }
        let step = spacing
        let firstX = floor((rect.minX - step / 2) / step) * step + step / 2
        let firstY = floor((rect.minY - step / 2) / step) * step + step / 2
        context.saveGState()
        defer { context.restoreGState() }

        switch self {
        case .plain:
            break
        case .grid, .ruled:
            context.setStrokeColor(Self.lineColor.cgColor)
            context.setLineWidth(0.75)
            var y = firstY
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            if self == .grid {
                var x = firstX
                while x <= rect.maxX {
                    context.move(to: CGPoint(x: x, y: rect.minY))
                    context.addLine(to: CGPoint(x: x, y: rect.maxY))
                    x += step
                }
            }
            context.strokePath()
        case .dots:
            context.setFillColor(Self.dotColor.cgColor)
            let r: CGFloat = 1.1
            var y = firstY
            while y <= rect.maxY {
                var x = firstX
                while x <= rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }
        }
    }
}

enum HandwritingExporter {
    struct Output {
        /// Gyazo へ上げる画像（白い紙＋模様＋線）
        let png: Data
        /// Vision 用の画像（白地＋線だけ）
        let ocrImage: Data
    }

    static let bottomMargin: CGFloat = 24
    static let scale: CGFloat = 2

    /// 何も描かれていなければ nil。
    static func export(drawing: PKDrawing, width: CGFloat, paper: PaperStyle) -> Output? {
        let bounds = drawing.bounds
        guard !bounds.isEmpty, width > 0 else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: ceil(bounds.maxY + bottomMargin))

        // PencilKit のインク色はダークモードで反転するので、白い紙に合わせてライト外観で描く
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)

        let png = renderer.pngData { ctx in
            PaperStyle.paperColor.setFill()
            ctx.fill(rect)
            paper.drawPattern(in: rect, context: ctx.cgContext)
            ink.draw(in: rect)
        }
        let ocrImage = renderer.pngData { ctx in
            PaperStyle.paperColor.setFill()
            ctx.fill(rect)
            ink.draw(in: rect)
        }
        return Output(png: png, ocrImage: ocrImage)
    }
}
