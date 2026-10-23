import Foundation
import Testing
@testable import AIQuizCore

private let sampleNotes = """
Augustus founded the empire and set the pattern later emperors followed.

## The Julio-Claudians
- **Augustus** ruled 27 BC to 14 AD.
- **Tiberius**, his stepson, followed and later withdrew to Capri.

## Why it matters
The succession was never formally defined, which caused repeated crises.
"""

@Suite("MarkdownParser")
struct MarkdownParserTests {
    @Test("headings, paragraphs with soft breaks, bullet and numbered lists")
    func basics() {
        let md = """
        # Title
        First line
        continues here.

        ## Section ##
        - one
        - **two**
          - nested
        1. first
        2) second
        """
        #expect(MarkdownParser.parse(md) == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line continues here."),
            .heading(level: 2, text: "Section"),
            .bulletList([
                MarkdownListItem(depth: 0, text: "one"),
                MarkdownListItem(depth: 0, text: "**two**"),
                MarkdownListItem(depth: 1, text: "nested")
            ]),
            .numberedList([
                MarkdownListItem(depth: 0, text: "first", number: 1),
                MarkdownListItem(depth: 0, text: "second", number: 2)
            ])
        ])
    }

    @Test("quotes, rules and fenced code kept verbatim")
    func quoteRuleCode() {
        let md = "> quoted\n> more\n\n---\n\n```swift\nlet x = 1\n  // indented\n```\n"
        #expect(MarkdownParser.parse(md) == [
            .quote("quoted more"),
            .rule,
            .code("let x = 1\n  // indented")
        ])
    }

    @Test("list item continuation lines join the item")
    func continuation() {
        #expect(MarkdownParser.parse("- a long item\n  that wraps\n- next") == [
            .bulletList([MarkdownListItem(depth: 0, text: "a long item that wraps"), MarkdownListItem(depth: 0, text: "next")])
        ])
    }

    @Test("not a heading or list without a space; CRLF handled; unterminated fence kept")
    func edgeCases() {
        #expect(MarkdownParser.parse("#hashtag\r\n-dash\r\n") == [.paragraph("#hashtag -dash")])
        #expect(MarkdownParser.parse("```\ncode") == [.code("code")])
        #expect(MarkdownParser.parse("") == [])
    }

    @Test("a bullet list directly after a numbered list starts a new list")
    func listSwitch() {
        #expect(MarkdownParser.parse("1. a\n- b") == [
            .numberedList([MarkdownListItem(depth: 0, text: "a", number: 1)]),
            .bulletList([MarkdownListItem(depth: 0, text: "b")])
        ])
    }

    @Test("a typical Markdown document parses into the expected outline")
    func sample() {
        let blocks = MarkdownParser.parse(sampleNotes)
        #expect(blocks.count == 5)
        #expect(blocks[1] == .heading(level: 2, text: "The Julio-Claudians"))
        if case .bulletList(let items) = blocks[2] { #expect(items.count == 2) } else { Issue.record("expected list") }
    }
}
