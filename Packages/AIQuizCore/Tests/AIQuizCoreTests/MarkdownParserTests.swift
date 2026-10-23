import Foundation
import Testing
@testable import AIQuizCore

/// A readable summary of a block, so expectations compare structure and plain text.
private func describe(_ block: MarkdownBlock) -> String {
    switch block {
    case .heading(let level, let text): return "h\(level) \(text.plainText)"
    case .paragraph(let text): return "p \(text.plainText)"
    case .list(let items):
        return "list " + items.map { "\(String(repeating: ">", count: $0.depth))\($0.ordered ? "\($0.number ?? 0)." : "-")\($0.text.plainText)" }.joined(separator: " | ")
    case .quote(let text): return "quote \(text.plainText)"
    case .code(let code, let language): return "code[\(language ?? "")] \(code)"
    case .table(let t):
        return "table \(t.alignments) " + ([t.header] + t.rows).map { $0.map(\.plainText).joined(separator: ",") }.joined(separator: " / ")
    case .rule: return "rule"
    }
}

private func parse(_ markdown: String) -> [String] {
    MarkdownParser.parse(markdown).map(describe)
}

@Suite("MarkdownParser (Foundation-backed)")
struct MarkdownParserTests {
    @Test("headings in both styles, paragraphs with soft breaks")
    func headingsAndParagraphs() {
        #expect(parse("# Title\nFirst line\ncontinues here.\n\nSetext\n======\n\n### Small ###") == [
            "h1 Title",
            "p First line continues here.",
            "h1 Setext",
            "h3 Small"
        ])
    }

    @Test("pipe table with header, rows and per-column alignment")
    func table() {
        let md = """
        | Model | Score | Notes |
        |:------|------:|:-----:|
        | A | 0.91 | *fast* |
        | B | 0.87 | slow |
        """
        #expect(parse(md) == ["table [AIQuizCore.MarkdownTable.Alignment.leading, AIQuizCore.MarkdownTable.Alignment.trailing, AIQuizCore.MarkdownTable.Alignment.center] Model,Score,Notes / A,0.91,fast / B,0.87,slow"])
    }

    @Test("table cells keep inline formatting")
    func tableInline() throws {
        let blocks = MarkdownParser.parse("| a | b |\n|---|---|\n| **bold** | `code` |")
        guard case .table(let t) = try #require(blocks.first) else { Issue.record("expected table"); return }
        let bold = t.rows[0][0]
        #expect(bold.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(t.rows[0][1].runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @Test("a table with an empty cell and a missing trailing cell")
    func raggedTable() {
        let blocks = MarkdownParser.parse("| a | b | c |\n|---|---|---|\n| 1 |  | 3 |\n| 4 | 5 |")
        guard case .table(let t) = blocks.first else { Issue.record("expected table"); return }
        #expect(t.header.count == 3)
        #expect(t.rows.count == 2)
        #expect(t.rows[0].map(\.plainText) == ["1", "", "3"])
    }

    @Test("bullet, nested and ordered lists")
    func lists() {
        #expect(parse("- one\n- **two**\n  - nested\n\n1. first\n2. second") == [
            "list -one | -two | >-nested",
            "list 1.first | 2.second"
        ])
    }

    @Test("ordered lists keep their starting number")
    func orderedStart() {
        #expect(parse("3. third\n4. fourth") == ["list 3.third | 4.fourth"])
    }

    @Test("a list item with two paragraphs stays one item")
    func multiParagraphItem() {
        #expect(parse("- first para\n\n  second para\n- next") == ["list -first para\nsecond para | -next"])
    }

    @Test("quote, rule and fenced code with language")
    func quoteRuleCode() {
        #expect(parse("> quoted\n> more\n\n---\n\n```swift\nlet x = 1\n  // indented\n```\n") == [
            "quote quoted more",
            "rule",
            "code[swift] let x = 1\n  // indented"
        ])
    }

    @Test("inline bold, italics and links survive in paragraphs")
    func inline() throws {
        let blocks = MarkdownParser.parse("Some **bold**, *italic* and [a link](https://example.com).")
        guard case .paragraph(let text) = try #require(blocks.first) else { Issue.record("expected paragraph"); return }
        #expect(text.plainText == "Some bold, italic and a link.")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com" })
        #expect(text.runs.allSatisfy { $0.presentationIntent == nil }, "block intents are stripped")
    }

    @Test("not a heading or list without a space; empty input")
    func edgeCases() {
        #expect(parse("#hashtag\n-dash") == ["p #hashtag -dash"])
        #expect(parse("") == [])
    }

    @Test("a mixed document keeps block order")
    func order() {
        let md = "Intro.\n\n## Section\n- a\n\n| x |\n|---|\n| 1 |\n\nOutro."
        #expect(parse(md) == ["p Intro.", "h2 Section", "list -a", "table [AIQuizCore.MarkdownTable.Alignment.leading] x / 1", "p Outro."])
    }
}
