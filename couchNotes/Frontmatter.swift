//
//  Frontmatter.swift
//  couchNotes
//
//  YAML フロントマター（created/updated）の解析・組み立て。
//  created/updated は 10桁エポック秒。ctime/mtime（ミリ秒）とは ×1000 / ÷1000 で変換する。
//

import Foundation

struct ParsedFrontmatter {
    var created: Int?          // エポック秒
    var updated: Int?          // エポック秒
    var extraLines: [String]   // created/updated 以外の行（保持する）
    var body: String           // フロントマターを除いた本文
}

enum FrontmatterParser {
    /// content を解析し、フロントマター項目と本文に分ける。先頭に正しいフロントマターが無ければ body=全文。
    static func split(_ content: String) -> ParsedFrontmatter {
        func plain() -> ParsedFrontmatter {
            ParsedFrontmatter(created: nil, updated: nil, extraLines: [], body: content)
        }
        guard content.hasPrefix("---") else { return plain() }

        let lines = content.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return plain() }

        // 閉じ "---" を探す
        var close: Int? = nil
        if lines.count > 1 {
            for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                close = i; break
            }
        }
        guard let closeIndex = close else { return plain() }

        var created: Int? = nil
        var updated: Int? = nil
        var extra: [String] = []
        for line in lines[1..<closeIndex] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let v = intValue(of: "created", in: trimmed) { created = v; continue }
            if let v = intValue(of: "updated", in: trimmed) { updated = v; continue }
            extra.append(line)
        }

        let body = (closeIndex + 1 < lines.count)
            ? lines[(closeIndex + 1)...].joined(separator: "\n")
            : ""
        return ParsedFrontmatter(created: created, updated: updated, extraLines: extra, body: body)
    }

    /// "key: value" 形式から整数値を取り出す（key 完全一致のみ）。
    private static func intValue(of key: String, in line: String) -> Int? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(":") else { return nil }
        return Int(rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    /// created/updated（秒）＋ 保持行 ＋ body から content を組み立てる。
    static func compose(createdSec: Int?, updatedSec: Int?, extra: [String], body: String) -> String {
        var fm: [String] = []
        if let c = createdSec { fm.append("created: \(c)") }
        if let u = updatedSec { fm.append("updated: \(u)") }
        fm.append(contentsOf: extra)
        guard !fm.isEmpty else { return body }
        return "---\n" + fm.joined(separator: "\n") + "\n---\n" + body
    }
}

// MARK: - 日時表示

enum DateDisplay {
    static let ymdhm: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH:mm"
        df.locale = Locale(identifier: "ja_JP")
        return df
    }()

    /// ミリ秒から "yyyyMMdd HH:mm"。nil は空文字。
    static func string(fromMs ms: Double?) -> String {
        guard let ms else { return "" }
        return ymdhm.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
