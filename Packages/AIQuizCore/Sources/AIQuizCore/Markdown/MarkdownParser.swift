import Foundation

/// A block of a Markdown document. Text keeps its inline formatting (bold, italics, code,
/// strikethrough, links) as `AttributedString` attributes, which SwiftUI `Text` renders.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list([MarkdownListItem])
    case quote(AttributedString)
    case code(String, language: String?)
    case table(MarkdownTable)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting depth: 0 for top level.
    public var depth: Int
    public var ordered: Bool
    /// The item's number in an ordered list.
    public var number: Int?
    public var text: AttributedString

    public init(depth: Int, ordered: Bool, number: Int? = nil, text: AttributedString) {
        self.depth = depth
        self.ordered = ordered
        self.number = number
        self.text = text
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public var alignments: [Alignment]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]

    public init(alignments: [Alignment], header: [AttributedString], rows: [[AttributedString]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

/// Splits Markdown into blocks using Foundation's built-in CommonMark + GitHub-flavored parser
/// (`AttributedString(markdown:)` with full syntax), which handles tables, nested lists, quotes,
/// code, rules and both heading styles (DECISIONS ADR-013, CR-008). This type only groups the
/// parsed runs into blocks; the app's `MarkdownView` draws them.
public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.paragraph(AttributedString(trimmed))]
        }
        return Builder(document).build()
    }

    /// Groups runs into leaf blocks (paragraph, header, code, rule, table cell), then folds leaves
    /// that share a list, quote or table into one block.
    private struct Builder {
        struct Leaf {
            var component: PresentationIntent.IntentType
            /// Enclosing components, innermost first (excluding the leaf itself).
            var ancestors: [PresentationIntent.IntentType]
            var text: AttributedString
        }

        let document: AttributedString

        init(_ document: AttributedString) {
            self.document = document
        }

        func build() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var pendingList: (id: Int, items: [MarkdownListItem], lastItemID: Int?)?
            var pendingQuote: (id: Int, text: AttributedString)?
            var pendingTable: (id: Int, table: MarkdownTable, rowID: Int?, row: [AttributedString])?

            func flushList() {
                if let list = pendingList { blocks.append(.list(list.items)) }
                pendingList = nil
            }
            func flushQuote() {
                if let quote = pendingQuote { blocks.append(.quote(quote.text)) }
                pendingQuote = nil
            }
            func flushTable() {
                guard var t = pendingTable else { return }
                if !t.row.isEmpty { t.table.rows.append(t.row) }
                // Empty cells produce no runs; pad every row to the column count.
                let width = max(t.table.alignments.count, t.table.header.count)
                t.table.header = Self.padded(t.table.header, to: width)
                t.table.rows = t.table.rows.map { Self.padded($0, to: width) }
                blocks.append(.table(t.table))
                pendingTable = nil
            }
            func flushAll() {
                flushList()
                flushQuote()
                flushTable()
            }

            for leaf in leaves() {
                // Tables
                if case .tableCell = leaf.component.kind {
                    let rowComponent = leaf.ancestors.first { if case .tableHeaderRow = $0.kind { true } else if case .tableRow = $0.kind { true } else { false } }
                    guard let tableComponent = leaf.ancestors.first(where: { if case .table = $0.kind { true } else { false } }),
                          case .table(let columns) = tableComponent.kind,
                          let rowComponent
                    else { continue }
                    if pendingTable?.id != tableComponent.identity {
                        flushAll()
                        pendingTable = (tableComponent.identity, MarkdownTable(alignments: columns.map(Self.alignment), header: [], rows: []), nil, [])
                    }
                    var t = pendingTable!
                    var column = 0
                    if case .tableCell(let index) = leaf.component.kind { column = index }
                    if case .tableHeaderRow = rowComponent.kind {
                        t.table.header = Self.placing(leaf.text, at: column, in: t.table.header)
                    } else {
                        if t.rowID != rowComponent.identity {
                            if !t.row.isEmpty { t.table.rows.append(t.row) }
                            t.row = []
                            t.rowID = rowComponent.identity
                        }
                        t.row = Self.placing(leaf.text, at: column, in: t.row)
                    }
                    pendingTable = t
                    continue
                }

                // Lists (a paragraph inside a list item)
                let listItems = leaf.ancestors.filter { if case .listItem = $0.kind { true } else { false } }
                if let item = listItems.first {
                    let lists = leaf.ancestors.filter {
                        switch $0.kind { case .orderedList, .unorderedList: true; default: false }
                    }
                    guard let innerList = lists.first, let outerList = lists.last else { continue }
                    if pendingList?.id != outerList.identity {
                        flushAll()
                        pendingList = (outerList.identity, [], nil)
                    }
                    var text = leaf.text
                    if case .codeBlock = leaf.component.kind {
                        text = AttributedString(String(leaf.text.characters).trimmingCharacters(in: .newlines))
                    }
                    if pendingList?.lastItemID == item.identity, var last = pendingList?.items.popLast() {
                        last.text += AttributedString("\n") + text
                        pendingList?.items.append(last)
                    } else {
                        var number: Int?
                        if case .listItem(let ordinal) = item.kind { number = ordinal }
                        var ordered = false
                        if case .orderedList = innerList.kind { ordered = true }
                        pendingList?.items.append(MarkdownListItem(depth: lists.count - 1, ordered: ordered, number: number, text: text))
                        pendingList?.lastItemID = item.identity
                    }
                    continue
                }

                // Block quotes
                if let quote = leaf.ancestors.last(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                    if pendingQuote?.id == quote.identity {
                        pendingQuote?.text += AttributedString("\n\n") + leaf.text
                    } else {
                        flushAll()
                        pendingQuote = (quote.identity, leaf.text)
                    }
                    continue
                }

                flushAll()
                switch leaf.component.kind {
                case .header(let level):
                    blocks.append(.heading(level: level, text: leaf.text))
                case .codeBlock(let language):
                    let code = String(leaf.text.characters)
                    blocks.append(.code(code.hasSuffix("\n") ? String(code.dropLast()) : code, language: language))
                case .thematicBreak:
                    blocks.append(.rule)
                default:
                    blocks.append(.paragraph(leaf.text))
                }
            }
            flushAll()
            return blocks
        }

        /// Consecutive runs that share their innermost leaf component, with that component's ancestry.
        func leaves() -> [Leaf] {
            var result: [Leaf] = []
            var currentID: Int?
            for run in document.runs {
                guard let intent = run.presentationIntent, let leafIndex = intent.components.firstIndex(where: Self.isLeaf) else { continue }
                let leaf = intent.components[leafIndex]
                var text = AttributedString(document[run.range])
                text.presentationIntent = nil
                if currentID == leaf.identity, !result.isEmpty {
                    result[result.count - 1].text += text
                } else {
                    result.append(Leaf(component: leaf, ancestors: Array(intent.components[(leafIndex + 1)...]), text: text))
                    currentID = leaf.identity
                }
            }
            return result
        }

        /// Puts a cell's text at its column, filling skipped (empty) columns.
        static func placing(_ text: AttributedString, at column: Int, in row: [AttributedString]) -> [AttributedString] {
            var row = padded(row, to: column + 1)
            row[column] = text
            return row
        }

        static func padded(_ row: [AttributedString], to width: Int) -> [AttributedString] {
            row.count >= width ? row : row + Array(repeating: AttributedString(""), count: width - row.count)
        }

        static func isLeaf(_ component: PresentationIntent.IntentType) -> Bool {
            switch component.kind {
            case .paragraph, .header, .codeBlock, .thematicBreak, .tableCell: return true
            default: return false
            }
        }

        static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment {
            switch column.alignment {
            case .center: return .center
            case .right: return .trailing
            default: return .leading
            }
        }
    }
}

extension AttributedString {
    /// The plain characters, for tests and accessibility.
    public var plainText: String { String(characters) }
}
