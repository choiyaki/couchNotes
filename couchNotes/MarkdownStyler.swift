//
//  MarkdownStyler.swift
//  couchNotes
//
//  MarkdownTextView.swift から分割（純粋なコード移動・ロジック変更なし）。
//

import UIKit

// MARK: - MarkdownStyler

enum MarkdownStyler {
    static let defaultFontSize:    CGFloat = 16
    static let defaultLineSpacing: CGFloat = 0

    private static let wikiLinkRegex = try? NSRegularExpression(pattern: #"\[\[[^\]]+\]\]"#)
    private static let blockIDRegex  = try? NSRegularExpression(
        pattern: #"\^[a-zA-Z0-9_-]+$"#,
        options: .anchorsMatchLines
    )

    /// タブの表示幅（見かけ上 ≒ 半角スペース2つ分。等幅フォント前提）。
    /// ぶら下げインデントの計算とも共有して、折り返し行のズレを防ぐ。
    static func tabWidth(for fontSize: CGFloat) -> CGFloat { fontSize * 1.2 }

    /// 行間とタブ幅を設定した段落スタイルを作る（全段落で共通の基準）。
    private static func makeParagraph(lineSpacing: CGFloat, fontSize: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        if lineSpacing > 0 { p.lineSpacing = lineSpacing }
        p.tabStops = []                               // 既定のタブストップを消し…
        p.defaultTabInterval = tabWidth(for: fontSize) // …一定間隔（≒2スペース）に揃える
        return p
    }

    static func baseAttributes(fontSize: CGFloat = defaultFontSize,
                               lineSpacing: CGFloat = defaultLineSpacing) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: makeParagraph(lineSpacing: lineSpacing, fontSize: fontSize),
        ]
    }

    static func apply(to storage: NSTextStorage,
                      notes: [NoteItem] = [],
                      fontSize: CGFloat = defaultFontSize,
                      lineSpacing: CGFloat = defaultLineSpacing) {
        let len = storage.length
        guard len > 0 else { return }
        style(storage, range: NSRange(location: 0, length: len),
              notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
    }

    /// 変更があった範囲の前後の段落だけを再スタイルする（打鍵ごとの軽量パス）。
    /// このエディタのスタイルは全て行内完結なので段落単位で安全。将来の複数行記法に備え前後±1段落広げる。
    static func applyIncremental(to storage: NSTextStorage,
                                 changed: NSRange,
                                 notes: [NoteItem] = [],
                                 fontSize: CGFloat = defaultFontSize,
                                 lineSpacing: CGFloat = defaultLineSpacing) {
        let len = storage.length
        guard len > 0 else { return }
        let ns  = storage.string as NSString
        let loc = min(max(0, changed.location), len)
        let safe = NSRange(location: loc, length: min(changed.length, len - loc))

        var para = ns.paragraphRange(for: safe)
        if para.location > 0 {   // 前の段落へ拡張
            let prev = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
            para = NSRange(location: prev.location, length: NSMaxRange(para) - prev.location)
        }
        if NSMaxRange(para) < len {   // 次の段落へ拡張
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 0))
            para = NSRange(location: para.location, length: NSMaxRange(next) - para.location)
        }
        style(storage, range: para, notes: notes, fontSize: fontSize, lineSpacing: lineSpacing)
    }

    /// 指定範囲をスタイルする共通処理。属性変更は beginEditing/endEditing でまとめ、
    /// レイアウトマネージャへの通知を1回に抑える。
    private static func style(_ storage: NSTextStorage,
                              range full: NSRange,
                              notes: [NoteItem],
                              fontSize: CGFloat,
                              lineSpacing: CGFloat) {
        let baseFont    = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let blockIDFont = UIFont.monospacedSystemFont(ofSize: max(fontSize * 0.69, 10), weight: .regular)

        storage.beginEditing()
        storage.addAttribute(.font,            value: baseFont,      range: full)
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.removeAttribute(.paragraphStyle,     range: full)
        storage.removeAttribute(.wikiLinkTarget,     range: full)
        storage.removeAttribute(.externalLinkURL,    range: full)
        storage.removeAttribute(.underlineStyle,     range: full)

        // 行間とタブ幅を範囲全体に適用（リスト・画像行は後で上書き）
        storage.addAttribute(.paragraphStyle,
                             value: makeParagraph(lineSpacing: lineSpacing, fontSize: fontSize),
                             range: full)

        (storage.string as NSString).enumerateSubstrings(in: full, options: .byLines) { sub, lineRange, _, _ in
            guard let line = sub else { return }
            styleLine(line, at: lineRange, in: storage, baseFont: baseFont, lineSpacing: lineSpacing)
        }

        styleWikiLinks(in: storage, range: full, notes: notes)
        styleExternalLinks(in: storage, range: full)
        styleImageLines(in: storage, range: full, lineSpacing: lineSpacing, fontSize: fontSize)
        styleBlockIDs(in: storage, range: full, font: blockIDFont)
        storage.endEditing()
    }

    // 画像リンク `![](http…)`（リモート）。capture 1 = URL。
    static let imageLinkRegex = try? NSRegularExpression(
        pattern: #"!\[[^\]]*\]\((https?://[^)\s]+)\)"#
    )

    /// 画像リンク行に「段落下の余白」を設定し、画像オーバーレイの居場所を確保する。
    /// テキスト（文字）は増やさないのでカーソル挙動・保存本文には影響しない。
    private static func styleImageLines(in s: NSTextStorage, range full: NSRange, lineSpacing: CGFloat, fontSize: CGFloat) {
        guard let regex = imageLinkRegex else { return }
        let ns = s.string as NSString
        for m in regex.matches(in: s.string, range: full) where m.numberOfRanges > 1 {
            let url = ns.substring(with: m.range(at: 1))
            let lineRange = ns.lineRange(for: m.range)
            let para = makeParagraph(lineSpacing: lineSpacing, fontSize: fontSize)
            para.paragraphSpacing = EditorImageStore.shared.displayHeight(for: url) + 16
            s.addAttribute(.paragraphStyle, value: para, range: lineRange)
        }
    }

    private static func styleLine(_ line: String, at range: NSRange, in s: NSTextStorage,
                                  baseFont: UIFont, lineSpacing: CGFloat) {
        let fontSize = baseFont.pointSize
        // 見出し（タブ前置なし想定）
        if line.hasPrefix("### ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.1875, weight: .semibold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(4, range.length)))
            return
        }
        if line.hasPrefix("## ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.375, weight: .bold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(3, range.length)))
            return
        }
        if line.hasPrefix("# ") {
            let f = UIFont.systemFont(ofSize: fontSize * 1.625, weight: .bold)
            s.addAttribute(.font, value: f, range: range)
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: range.location, length: min(2, range.length)))
            return
        }

        // リスト項目（タブ・半角スペース両方の先頭インデントに対応）
        let leadingWS   = line.prefix(while: { $0 == "\t" || $0 == " " })
        let indentCount = leadingWS.count
        let tabCount    = leadingWS.filter { $0 == "\t" }.count
        let spaceCount  = leadingWS.filter { $0 == " " }.count
        let stripped    = String(line.dropFirst(indentCount))
        let markerLoc   = range.location + indentCount
        let markerAvail = max(0, range.length - indentCount)

        let prefixForMeasure: String

        if stripped.hasPrefix("- [ ]") || stripped.hasPrefix("* [ ]") {
            s.addAttribute(.foregroundColor,
                           value: UIColor.systemBlue.withAlphaComponent(0.8),
                           range: NSRange(location: markerLoc, length: min(5, markerAvail)))
            prefixForMeasure = "- [ ] "

        } else if stripped.hasPrefix("- [x]") || stripped.hasPrefix("* [x]") {
            s.addAttribute(.foregroundColor, value: UIColor.systemGreen,
                           range: NSRange(location: markerLoc, length: min(5, markerAvail)))
            if markerAvail > 6 {
                let bodyRange = NSRange(location: markerLoc + 6, length: markerAvail - 6)
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: bodyRange)
                s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: bodyRange)
            }
            prefixForMeasure = "- [x] "

        } else if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
            s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                           range: NSRange(location: markerLoc, length: min(2, markerAvail)))
            prefixForMeasure = String(stripped.prefix(2))

        } else {
            return
        }

        // ぶら下げインデント（タブは共通のタブ幅、スペースは実測幅 + プレフィックス幅）
        let tabW        = tabWidth(for: fontSize)
        let spaceWidth  = (" " as NSString).size(withAttributes: [.font: baseFont]).width
        let prefixWidth = (prefixForMeasure as NSString)
            .size(withAttributes: [.font: baseFont]).width
        let para = makeParagraph(lineSpacing: lineSpacing, fontSize: fontSize)
        para.headIndent  = CGFloat(tabCount) * tabW + CGFloat(spaceCount) * spaceWidth + prefixWidth
        s.addAttribute(.paragraphStyle, value: para, range: range)
    }

    private static func styleWikiLinks(in s: NSTextStorage, range: NSRange, notes: [NoteItem]) {
        guard let regex = wikiLinkRegex else { return }
        for m in regex.matches(in: s.string, range: range) {
            guard m.range.length > 4 else { continue }
            let innerRange = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            let linkText   = (s.string as NSString).substring(with: innerRange)
            let lower      = linkText.lowercased()
            let exists     = notes.contains { $0.shortTitle.lowercased() == lower }
            s.addAttribute(.foregroundColor,
                           value: exists ? UIColor.systemBlue : UIColor.systemBlue.withAlphaComponent(0.35),
                           range: m.range)
            s.addAttribute(.wikiLinkTarget, value: linkText + ".md", range: m.range)
        }
    }

    // 画像でない Markdown リンク `[text](http…)`（先頭の ! を除外）。capture 1 = URL。
    private static let mdLinkRegex = try? NSRegularExpression(
        pattern: #"(?<!\!)\[[^\]]*\]\((https?://[^)\s]+)\)"#
    )
    // 裸の URL（http/https）。
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s)\]]+"#
    )

    /// 外部リンク（Markdown リンク／裸 URL）に色・下線とタップ用 URL 属性を付ける。
    private static func styleExternalLinks(in s: NSTextStorage, range: NSRange) {
        let ns = s.string as NSString

        func mark(_ matchRange: NSRange, url: String) {
            s.addAttribute(.externalLinkURL, value: url, range: matchRange)
            s.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: matchRange)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: matchRange)
        }

        // 1) Markdown リンク（`![]()` 画像は除外）
        if let regex = mdLinkRegex {
            for m in regex.matches(in: s.string, range: range) where m.numberOfRanges > 1 {
                let urlRange = m.range(at: 1)
                guard urlRange.location != NSNotFound else { continue }
                mark(m.range, url: ns.substring(with: urlRange))
            }
        }

        // 2) 裸 URL（既にリンク属性が付いている範囲＝Markdown リンク内は除外）
        if let regex = bareURLRegex {
            for m in regex.matches(in: s.string, range: range) {
                if s.attribute(.externalLinkURL, at: m.range.location, effectiveRange: nil) != nil { continue }
                mark(m.range, url: ns.substring(with: m.range))
            }
        }
    }

    private static func styleBlockIDs(in s: NSTextStorage, range: NSRange, font: UIFont) {
        guard let regex = blockIDRegex else { return }
        for m in regex.matches(in: s.string, range: range) {
            s.addAttribute(.font,            value: font,                   range: m.range)
            s.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: m.range)
        }
    }
}
