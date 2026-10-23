import Foundation

/// A block of Markdown. Inline formatting (bold, italic, code, links) stays inside the text and
/// is rendered by the app with `AttributedString(markdown:)` (DECISIONS ADR-013).
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([MarkdownListItem])
    case numberedList([MarkdownListItem])
    case quote(String)
    case code(String)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting depth: 0 for top level, 1 for two to three spaces of indent, and so on.
    public var depth: Int
    public var text: String
    /// The item's number in a numbered list.
    public var number: Int?

    public init(depth: Int, text: String, number: Int? = nil) {
        self.depth = depth
        self.text = text
        self.number = number
    }
}

/// A small block-level Markdown parser covering what study notes use: ATX headings, paragraphs,
/// bullet and numbered lists (nested by indent), block quotes, fenced code and horizontal rules.
public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var list: [MarkdownListItem] = []
        var listIsNumbered = false
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: " ")))
                quote.removeAll()
            }
        }
        func flushList() {
            if !list.isEmpty {
                blocks.append(listIsNumbered ? .numberedList(list) : .bulletList(list))
                list.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything verbatim until the closing fence.
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                code = []
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var body = trimmed.dropFirst()
                if body.first == " " { body = body.dropFirst() }
                quote.append(String(body))
                continue
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let depth = indent / 2

            if let item = parseBullet(trimmed) {
                flushParagraph()
                flushQuote()
                if !list.isEmpty && listIsNumbered && depth == 0 { flushList() }
                if list.isEmpty { listIsNumbered = false }
                list.append(MarkdownListItem(depth: list.isEmpty ? 0 : depth, text: item))
                continue
            }

            if let (number, item) = parseNumbered(trimmed) {
                flushParagraph()
                flushQuote()
                if !list.isEmpty && !listIsNumbered && depth == 0 { flushList() }
                if list.isEmpty { listIsNumbered = true }
                list.append(MarkdownListItem(depth: list.isEmpty ? 0 : depth, text: item, number: number))
                continue
            }

            // A continuation line inside a list item.
            if !list.isEmpty && indent >= 2 {
                list[list.count - 1].text += " " + trimmed
                continue
            }
            if !quote.isEmpty {
                quote.append(trimmed)
                continue
            }
            flushList()
            paragraph.append(trimmed)
        }

        if let open = code {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    static func parseHeading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func parseBullet(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func parseNumbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let body = rest.dropFirst()
        guard body.first == " " else { return nil }
        return (number, body.trimmingCharacters(in: .whitespaces))
    }
}
