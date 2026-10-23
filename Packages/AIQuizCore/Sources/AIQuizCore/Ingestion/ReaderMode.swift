import Foundation
import SwiftSoup

/// The readable part of a web page.
public struct ExtractedArticle: Sendable, Equatable {
    public var title: String?
    /// Markdown-ish text: `#`/`##` headings, paragraphs, `-` list items, `>` quotes.
    public var text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

/// Reader-mode extraction (SPEC F-21): picks `<article>`, `<main>`, or the densest text
/// container, drops navigation, asides, footers, scripts, styles and forms, and keeps
/// headings, paragraphs, list items and quotes.
public enum ReaderModeExtractor {
    public enum Failure: LocalizedError, Equatable {
        case noArticle
        /// Too little text: a paywall stub, a login page, or an index page.
        case tooShort(Int)

        public var errorDescription: String? {
            switch self {
            case .noArticle:
                return "This page has no readable article. Paste the text instead."
            case .tooShort:
                return "This page has too little text to make a quiz (it may be behind a paywall or a login). Paste the text instead."
            }
        }
    }

    /// Below this many characters the page is treated as a stub.
    public static let minimumCharacters = 280

    /// A desktop browser User-Agent, so sites serve their full article (F-21).
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let removedTags = "script, style, noscript, nav, aside, footer, header, form, iframe, svg, button, select, input, template, figure > figcaption"
    private static let boilerplate = try? NSRegularExpression(
        pattern: "(^|[-_ ])(nav|navbar|navbox|navigation|menu|footer|sidebar|comment|comments|share|social|subscribe|newsletter|promo|advert|ads|cookie|related|breadcrumb|banner|masthead|toc|infobox)([-_ ]|$)",
        options: [.caseInsensitive]
    )

    public static func extract(html: String) throws -> ExtractedArticle {
        let document: Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            throw Failure.noArticle
        }
        let title = pageTitle(document)
        _ = try? document.select(removedTags).remove()
        _ = try? document.select("[role=navigation], [role=banner], [role=contentinfo], [aria-hidden=true], [hidden]").remove()
        removeBoilerplate(document)

        guard let root = bestContainer(document) else { throw Failure.noArticle }
        let text = render(root)
        guard !text.isEmpty else { throw Failure.noArticle }
        guard text.count >= minimumCharacters else { throw Failure.tooShort(text.count) }
        return ExtractedArticle(title: title, text: text)
    }

    /// Decodes a page using the charset from the `Content-Type` header or a `<meta>` tag,
    /// falling back to UTF-8 and then Windows-1252.
    public static func decode(_ data: Data, contentType: String?) -> String {
        if let name = charset(in: contentType) ?? metaCharset(data), let encoding = encoding(named: name),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Picking the article

    private static func pageTitle(_ document: Document) -> String? {
        let candidates = [
            (try? document.select("meta[property=og:title]").first()?.attr("content")) ?? nil,
            try? document.title(),
            (try? document.select("h1").first()?.text()) ?? nil
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func removeBoilerplate(_ document: Document) {
        guard let regex = boilerplate, let all = try? document.select("div, section, ul, ol, table, span, p") else { return }
        for element in all.array() {
            let tokens = [(try? element.className()) ?? "", element.id()].joined(separator: " ")
            guard !tokens.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let range = NSRange(tokens.startIndex..., in: tokens)
            if regex.firstMatch(in: tokens, range: range) != nil {
                try? element.remove()
            }
        }
    }

    /// `<article>` (the longest), then `<main>`, then the element whose direct paragraphs
    /// hold the most text.
    private static func bestContainer(_ document: Document) -> Element? {
        if let articles = try? document.select("article").array(), !articles.isEmpty {
            return articles.max { textLength($0) < textLength($1) }
        }
        if let main = try? document.select("main, [role=main]").first() {
            return main
        }
        var scores: [ObjectIdentifier: (Element, Int)] = [:]
        for p in (try? document.select("p").array()) ?? [] {
            guard let parent = p.parent() else { continue }
            let length = ((try? p.text()) ?? "").count
            let key = ObjectIdentifier(parent)
            scores[key] = (parent, (scores[key]?.1 ?? 0) + length)
        }
        return scores.values.max { $0.1 < $1.1 }?.0 ?? document.body()
    }

    private static func textLength(_ element: Element) -> Int {
        ((try? element.text()) ?? "").count
    }

    // MARK: Rendering

    private static func render(_ root: Element) -> String {
        var blocks: [String] = []
        let selector = "h1, h2, h3, h4, h5, h6, p, li, blockquote, pre"
        for element in (try? root.select(selector).array()) ?? [] {
            // A paragraph inside a list item or quote is rendered with its parent.
            if element.tagName() == "p", element.parents().array().contains(where: { ["li", "blockquote"].contains($0.tagName()) }) { continue }
            let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let block: String
            switch element.tagName() {
            case "h1": block = "# " + text
            case "h2", "h3", "h4", "h5", "h6": block = "## " + text
            case "li": block = "- " + text
            case "blockquote": block = "> " + text
            default: block = text
            }
            if blocks.last != block { blocks.append(block) }
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Charsets

    private static func charset(in contentType: String?) -> String? {
        guard let contentType, let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        return contentType[range.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
    }

    private static func metaCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "<meta[^>]+charset=[\"']?([A-Za-z0-9_\\-]+)", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let range = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[range])
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// Splits long text into parts that fit a model's context budget (SPEC §7.4): on paragraph
/// boundaries, then sentences, then a hard cut.
public enum Chunker {
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(200, maxCharacters)
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }
        func add(_ piece: String, separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= limit {
                current += separator + piece
            } else {
                flush()
                current = piece
            }
        }

        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if paragraph.count <= limit {
                add(paragraph, separator: "\n\n")
                continue
            }
            for sentence in sentences(paragraph) {
                if sentence.count <= limit {
                    add(sentence, separator: " ")
                } else {
                    flush()
                    var rest = Substring(sentence)
                    while !rest.isEmpty {
                        chunks.append(String(rest.prefix(limit)))
                        rest = rest.dropFirst(limit)
                    }
                }
            }
        }
        flush()
        return chunks
    }

    private static func sentences(_ paragraph: String) -> [String] {
        var result: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { result.append(s) }
        }
        return result.isEmpty ? [paragraph] : result
    }
}
