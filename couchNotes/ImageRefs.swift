//
//  ImageRefs.swift
//  couchNotes
//
//  ノートの本文から、画像サーバー（couchimg）の URL を抜き出す。
//  「画像 → 貼られているノート」の端末側の対応表（image_refs）と、画像内の文字での検索に使う。
//
//  サーバー側（../couchimg/server/lib/imageRefs.mjs）と同じ規則で動かす。規則の例は
//  couchNotesTests/imageRefs.cases.json（../couchimg/server/test/imageRefs.cases.json の写し）にあり、両方のテストで読む。
//  規則を変えるときは、先に例の表へ1行足し、両方を直す。
//
//  規則（上から順に適用する）:
//   1. コードブロック（``` か ~~~ の柵。行頭の空白と引用の > は無視）の中は数えない。閉じ忘れは最後までコード
//   2. インラインコード（同じ数のバッククォートで挟んだ部分。空行はまたがない）と
//      HTML コメント（<!-- から -->。閉じ忘れは最後まで）の中は数えない。先に始まったほうが勝つ
//   3. バックスラッシュ＋記号は「ただの文字」にする（\![…] は画像ではない。\` はコードの始まりではない）
//   4. URL は http(s):// から、空白・日本語・括弧・引用符などの手前まで。URL の中に埋まった別の URL は数えない
//   5. ホスト名は完全一致（大文字小文字は無視）。直後のパスが ID そのもの。拡張子・クエリ・後ろのパスはあってもよい
//   6. embed（画像として貼ってある）= ![…](URL) / ![…][ラベル] が指す定義 / <img src=URL>。それ以外は link
//   7. 同じ画像が何度出てきても1件。1か所でも embed なら embed。順番は最初に出てきた順
//

import Foundation

struct ImageRef: Equatable {
    enum Kind: String { case embed, link }
    let id: String
    var ext: String?
    var kind: Kind
}

enum ImageRefs {
    struct Config {
        let hosts: [String]
        let idPattern: String
    }

    static let couchimg = Config(hosts: ["img.choiyaki.com"], idPattern: "[0-9a-f]{32}")
    static let gyazo = Config(hosts: ["gyazo.com", "i.gyazo.com"], idPattern: "[0-9a-f]{32}")

    // JavaScript 版と同じ正規表現（位置は UTF-16 で数える。NSString と同じ）
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // パターンは固定の文字列なので、作れないことはない
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let alt = #"(?:[^\[\]\n]|\[[^\[\]\n]*\])*"#
    private static let fenceOpen = re(#"^[ \t>]*(`{3,}|~{3,})([\s\S]*)$"#)
    private static let fenceClose = re(#"^[ \t>]*(`{3,}|~{3,})[ \t\r]*$"#)
    // 空白・制御文字・ASCII 以外・括弧・引用符の手前まで（印字できる ASCII から、区切りの記号を除いたもの）。
    // 大文字小文字を無視する指定は使わない: 指定すると ICU が k や s に似た文字（K・ſ）まで同じ扱いにして、JavaScript 版と食い違う
    private static let urlToken = re(#"[Hh][Tt][Tt][Pp][Ss]?://[\x{21}-\x{7e}&&[^<>"'`()\[\]]]+"#)
    private static let inlineImage = re(#"!\["# + alt + #"\]\([ \t]*<?(?=https?://)"#, [.caseInsensitive])
    private static let imgTag = re(#"<img\b[^<>]*?\bsrc[ \t]*=[ \t]*["']?(?=https?://)"#, [.caseInsensitive])
    private static let refImage = re(#"!\[("# + alt + #")\](?:\[([^\]\n]*)\])?(?!\()"#)
    private static let refDef = re(#"^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*<?(?=https?://)"#, [.caseInsensitive, .anchorsMatchLines])
    private static let spaces = re(#"\s+"#)

    private static func full(_ s: NSString) -> NSRange { NSRange(location: 0, length: s.length) }

    // 規則1: 柵で囲んだコードブロックの行を空行にする
    private static func dropFences(_ text: String) -> String {
        var out: [String] = []
        var fence: (ch: unichar, len: Int)?
        for line in (text as NSString).components(separatedBy: "\n") {
            let ns = line as NSString
            if let f = fence {
                if let m = fenceClose.firstMatch(in: line, range: full(ns)) {
                    let run = m.range(at: 1)
                    if ns.character(at: run.location) == f.ch, run.length >= f.len { fence = nil }
                }
                out.append("")
                continue
            }
            if let m = fenceOpen.firstMatch(in: line, range: full(ns)) {
                let run = m.range(at: 1)
                let ch = ns.character(at: run.location)
                // バッククォートの柵は、同じ行の後ろにバッククォートがあれば柵ではない（```a``` はインラインコード）
                let rest = ns.substring(with: m.range(at: 2))
                if !(ch == 0x60 && rest.contains("`")) {
                    fence = (ch, run.length)
                    out.append("")
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func isAsciiPunct(_ c: unichar) -> Bool {
        (0x21...0x2f).contains(c) || (0x3a...0x40).contains(c) || (0x5b...0x60).contains(c) || (0x7b...0x7e).contains(c)
    }

    // 規則2・3: インラインコード・HTML コメント・バックスラッシュ＋記号を空白1つに置き換える
    private static func dropInline(_ text: String) -> String {
        let u = Array(text.utf16)
        let n = u.count
        var out: [unichar] = []
        out.reserveCapacity(n)
        let tick: unichar = 0x60, space: unichar = 0x20, nl: unichar = 0x0a
        // 閉じのバッククォートを探すたびに段落を読み直すと長い入力で遅くなるので、段落（次の空行まで）ごとに1回だけ、
        // バッククォートの並びを「個数 → 始まる位置の一覧」にまとめておく
        var paraEnd = -1
        var runs: [Int: (at: [Int], next: Int)] = [:]

        // from 以降で最初の空行（改行・空白だけの並び・改行）の始まり。なければ末尾
        func blankLine(from: Int) -> Int {
            var p = from
            while p < n {
                if u[p] == nl {
                    var q = p + 1
                    while q < n, u[q] == space || u[q] == 0x09 || u[q] == 0x0d { q += 1 }
                    if q < n, u[q] == nl { return p }
                }
                p += 1
            }
            return n
        }
        func findClosingRun(from: Int, count: Int) -> Int {
            if from > paraEnd {
                paraEnd = blankLine(from: from)
                runs = [:]
                var j = from
                while j < paraEnd {
                    if u[j] != tick { j += 1; continue }
                    var k = j
                    while k < n, u[k] == tick { k += 1 }
                    runs[k - j, default: ([], 0)].at.append(j)
                    j = k
                }
            }
            guard var r = runs[count] else { return -1 }
            while r.next < r.at.count, r.at[r.next] < from { r.next += 1 }
            runs[count] = r
            return r.next < r.at.count ? r.at[r.next] + count : -1
        }

        var i = 0
        while i < n {
            let c = u[i]
            if c == 0x5c, i + 1 < n, isAsciiPunct(u[i + 1]) {
                out.append(space); i += 2
            } else if c == 0x3c, i + 3 < n, u[i + 1] == 0x21, u[i + 2] == 0x2d, u[i + 3] == 0x2d {
                // <!-- … -->
                var end = -1
                var j = i + 4
                while j + 2 < n {
                    if u[j] == 0x2d, u[j + 1] == 0x2d, u[j + 2] == 0x3e { end = j; break }
                    j += 1
                }
                if end < 0 { break }
                out.append(space); i = end + 3
            } else if c == tick {
                var count = 1
                while i + count < n, u[i + count] == tick { count += 1 }
                // ちょうど count 個のバッククォートの並びを、空行より手前で探す
                let close = findClosingRun(from: i + count, count: count)
                if close < 0 { out.append(contentsOf: u[i..<(i + count)]); i += count } else { out.append(space); i = close }
            } else {
                out.append(c); i += 1
            }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    /// コードブロック・インラインコード・HTML コメントを取り除いた本文
    static func stripCode(_ text: String) -> String { dropInline(dropFences(text)) }

    private static func endPositions(_ regex: NSRegularExpression, _ body: String, _ ns: NSString) -> Set<Int> {
        var set = Set<Int>()
        regex.enumerateMatches(in: body, range: full(ns)) { m, _, _ in
            if let m { set.insert(m.range.location + m.range.length) }
        }
        return set
    }

    private static func normLabel(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return spaces.stringByReplacingMatches(in: trimmed, range: full(trimmed as NSString), withTemplate: " ").lowercased()
    }

    /// 本文 → [ImageRef]。ext は拡張子（小文字。なければ nil）
    static func extract(_ text: String, config: Config = couchimg) -> [ImageRef] {
        if text.isEmpty { return [] }
        let body = stripCode(text)
        let ns = body as NSString
        let pathRe = re("^/(" + config.idPattern + #")(?:\.([a-z0-9]{1,8}))?(?![a-z0-9_-])"#, [.caseInsensitive])

        var embedAt = endPositions(inlineImage, body, ns)
        embedAt.formUnion(endPositions(imgTag, body, ns))
        // 参照形式: 画像から使われているラベルの定義だけを embed にする
        var usedLabels = Set<String>()
        refImage.enumerateMatches(in: body, range: full(ns)) { m, _, _ in
            guard let m else { return }
            let second = m.range(at: 2)
            let label = second.location != NSNotFound && second.length > 0 ? ns.substring(with: second) : ns.substring(with: m.range(at: 1))
            usedLabels.insert(normLabel(label))
        }
        refDef.enumerateMatches(in: body, range: full(ns)) { m, _, _ in
            guard let m else { return }
            if usedLabels.contains(normLabel(ns.substring(with: m.range(at: 1)))) {
                embedAt.insert(m.range.location + m.range.length)
            }
        }

        var order: [String] = []                 // 最初に出てきた順
        var found: [String: ImageRef] = [:]
        urlToken.enumerateMatches(in: body, range: full(ns)) { m, _, _ in
            guard let m else { return }
            let token = ns.substring(with: m.range) as NSString
            let sep = token.range(of: "://")
            let rest = token.substring(from: sep.location + 3) as NSString
            let hostEnd = rest.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#"))
            guard hostEnd.location != NSNotFound,
                  config.hosts.contains(rest.substring(to: hostEnd.location).lowercased()) else { return }
            let path = rest.substring(from: hostEnd.location)
            guard let p = pathRe.firstMatch(in: path, range: full(path as NSString)) else { return }
            let pns = path as NSString
            let id = pns.substring(with: p.range(at: 1)).lowercased()
            let extRange = p.range(at: 2)
            let ext = extRange.location != NSNotFound ? pns.substring(with: extRange).lowercased() : nil
            let kind: ImageRef.Kind = embedAt.contains(m.range.location) ? .embed : .link
            if let prev = found[id] {
                if prev.kind == .link, kind == .embed { found[id] = ImageRef(id: id, ext: ext, kind: .embed) }
            } else {
                found[id] = ImageRef(id: id, ext: ext, kind: kind)
                order.append(id)
            }
        }
        return order.compactMap { found[$0] }
    }
}
