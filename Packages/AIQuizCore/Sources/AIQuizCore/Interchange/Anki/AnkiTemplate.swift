import Foundation
import SwiftSoup

/// Renders an Anki card template the way Anki does for the parts that matter to text cards
/// (docs/anki-interchange.md §2.2): field references, `{{#Field}}` / `{{^Field}}` sections,
/// the `text:`, `cloze:`, `type:`, `hint:` and furigana filters, and `{{FrontSide}}`.
enum AnkiTemplate {
    enum Side { case question, answer }

    /// What a cloze card shows: on the question side the active cloze becomes `{{blank}}`.
    struct ClozeContext {
        /// 1 for c1.
        var number: Int
    }

    struct Context {
        var fields: [String: String]
        var side: Side
        var frontSide: String = ""
        var cloze: ClozeContext?
        var tags: [String] = []
        var deck: [String] = []
        var cardName = ""
        var notetypeName = ""
    }

    static func render(_ template: String, _ context: Context) -> String {
        render(parse(template), context)
    }

    // MARK: Parsing

    indirect enum Node {
        case text(String)
        case field(name: String, filters: [String])
        case section(name: String, inverted: Bool, children: [Node])
    }

    static func parse(_ template: String) -> [Node] {
        var tokens: [(isTag: Bool, value: String)] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            if open.lowerBound > rest.startIndex { tokens.append((false, String(rest[..<open.lowerBound]))) }
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                tokens.append((false, String(rest[open.lowerBound...])))
                rest = ""
                break
            }
            tokens.append((true, rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { tokens.append((false, String(rest))) }
        var index = 0
        return nodes(tokens, &index, closing: nil)
    }

    private static func nodes(_ tokens: [(isTag: Bool, value: String)], _ index: inout Int, closing: String?) -> [Node] {
        var result: [Node] = []
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.isTag else {
                result.append(.text(token.value))
                continue
            }
            if let first = token.value.first, first == "#" || first == "^" {
                let name = String(token.value.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(.section(name: name, inverted: first == "^", children: nodes(tokens, &index, closing: name)))
            } else if token.value.hasPrefix("/") {
                if closing != nil { return result }
            } else {
                let parts = token.value.components(separatedBy: ":")
                result.append(.field(name: parts.last ?? "", filters: parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }))
            }
        }
        return result
    }

    // MARK: Rendering

    private static func render(_ nodes: [Node], _ context: Context) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let text):
                return text
            case .field(let name, let filters):
                return field(name, filters: filters, context)
            case .section(let name, let inverted, let children):
                let present = !HTMLText.plain(value(of: name, context)).isEmpty
                return present != inverted ? render(children, context) : ""
            }
        }
        .joined()
    }

    private static func value(of name: String, _ context: Context) -> String {
        switch name {
        case "FrontSide": return context.frontSide
        case "Tags": return context.tags.joined(separator: " ")
        case "Deck": return context.deck.joined(separator: "::")
        case "Subdeck": return context.deck.last ?? ""
        case "Card": return context.cardName
        case "Type": return context.notetypeName
        default:
            return context.fields[name] ?? context.fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
    }

    private static func field(_ name: String, filters: [String], _ context: Context) -> String {
        var text = value(of: name, context)
        // Filters apply right to left, as in Anki.
        for filter in filters.reversed() {
            switch filter {
            case "text":
                text = HTMLText.plain(text)
            case "cloze":
                text = Cloze.anki(text, number: context.cloze?.number ?? 0, side: context.side).text
            case "type":
                // The question side shows an input box; the answer side compares with the field.
                text = context.side == .question ? "" : text
            case "hint":
                // A "Show hint" link in Anki; AIQuiz keeps hints out of the prompt.
                text = ""
            case "furigana", "kanji":
                text = text.replacingOccurrences(of: #" ?([^ \[\]]+)\[[^\]]*\]"#, with: "$1", options: .regularExpression)
            case "kana":
                text = text.replacingOccurrences(of: #" ?[^ \[\]]+\[([^\]]*)\]"#, with: "$1", options: .regularExpression)
            default:
                break
            }
        }
        return text
    }
}

extension Cloze {
    /// One Anki cloze card: `{{c1::answer::hint}}` deletions for `number` become `{{blank}}`
    /// on the question side; every other deletion, and all of them on the answer side, show
    /// their text. Returns the answers and hints of the active deletion, in order.
    static func anki(_ text: String, number: Int, side: AnkiTemplate.Side) -> (text: String, answers: [String], hints: [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#, options: [.dotMatchesLineSeparators]) else {
            return (text, [], [])
        }
        let source = text as NSString
        var output = ""
        var answers: [String] = []
        var hints: [String] = []
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let n = Int(source.substring(with: match.range(at: 1))) ?? 0
            let answer = source.substring(with: match.range(at: 2))
            if n == number {
                answers.append(answer)
                if match.range(at: 3).location != NSNotFound { hints.append(source.substring(with: match.range(at: 3))) }
                output += side == .question ? marker : answer
            } else {
                output += answer
            }
            last = match.range.location + match.range.length
        }
        output += source.substring(from: last)
        return (output, answers, hints)
    }

    /// The cloze numbers a note's text uses, in order (one Anki card each).
    static func ankiNumbers(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{c(\d+)::"#) else { return [] }
        let source = text as NSString
        let numbers = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { Int(source.substring(with: $0.range(at: 1))) }
        return Array(Set(numbers)).sorted()
    }
}

/// HTML from Anki fields as plain text: line breaks kept, entities decoded, media removed.
enum HTMLText {
    /// Characters SwiftSoup's whitespace normalisation leaves alone: a `<br>` (each one a
    /// line break) and a block boundary (any number of them make one line break).
    private static let lineBreak = "\u{2028}"
    private static let blockBreak = "\u{2029}"

    static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") || html.contains("[sound:") else {
            return tidy(html)
        }
        var marked = html.replacingOccurrences(of: #"\[sound:[^\]]*\]"#, with: "", options: .regularExpression)
        marked = marked.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: lineBreak, options: .regularExpression)
        marked = marked.replacingOccurrences(of: #"(?i)</?(div|p|li|ul|ol|h[1-6]|tr|table|blockquote|pre)(\s[^>]*)?>|<hr[^>]*>"#, with: blockBreak, options: .regularExpression)
        guard let document = try? SwiftSoup.parseBodyFragment(marked), let body = document.body() else { return tidy(html) }
        _ = try? body.select("style, script").remove()
        var text = ((try? body.text()) ?? "").replacingOccurrences(of: lineBreak, with: "\n")
        text = text.replacingOccurrences(of: "[ \t]*\n*\u{2029}[\u{2029}\n \t]*", with: "\n", options: .regularExpression)
        return tidy(text)
    }

    /// Trims every line, turns no-break spaces into spaces, drops blank lines at the ends
    /// and runs of them in between.
    private static func tidy(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// Images and sounds referenced by a field.
    static func media(_ html: String) -> (images: Int, sounds: Int) {
        let images = html.components(separatedBy: "<img").count - 1 + html.components(separatedBy: "<IMG").count - 1
        let sounds = html.components(separatedBy: "[sound:").count - 1
        return (images, sounds)
    }
}
