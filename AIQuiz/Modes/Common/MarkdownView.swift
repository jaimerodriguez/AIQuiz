import SwiftUI
import AIQuizCore

/// Renders Markdown natively at the user's reading size (DECISIONS ADR-013, CR-008).
/// Foundation parses the document (`MarkdownParser`); this view draws the blocks. Inline bold,
/// italics, code, strikethrough and links are `AttributedString` attributes `Text` renders.
struct MarkdownView: View {
    let markdown: String
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let typo = settings.quizFontSize
        let blocks = MarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: typo.bodyPoints * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, typo: typo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, typo: QuizFontSize) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level, typo), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? typo.bodyPoints * 0.4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
                .font(typo.bodyFont)
        case .list(let items):
            VStack(alignment: .leading, spacing: typo.bodyPoints * 0.3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker(item))
                            .font(typo.bodyFont)
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(typo.bodyFont)
                    }
                    .padding(.leading, CGFloat(item.depth) * typo.bodyPoints)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tint.opacity(0.6))
                    .frame(width: 3)
                Text(text)
                    .font(typo.bodyFont)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: typo.captionPoints, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        case .table(let table):
            MarkdownTableView(table: table, fontSize: max(typo.captionPoints, typo.bodyPoints * 0.8))
        case .rule:
            Divider()
        }
    }

    private func marker(_ item: MarkdownListItem) -> String {
        if item.ordered { return "\(item.number ?? 1)." }
        return item.depth == 0 ? "•" : "◦"
    }

    private func headingSize(_ level: Int, _ typo: QuizFontSize) -> CGFloat {
        switch level {
        case 1: return typo.promptPoints * 0.85
        case 2: return typo.emphasisPoints
        default: return typo.bodyPoints + 2
        }
    }
}

/// A Markdown table: bold header row, cell borders, per-column alignment, and horizontal
/// scrolling when it is wider than the screen.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column, header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column, header: false, striped: index.isMultiple(of: 2))
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.table")
    }

    private func cell(_ text: AttributedString, column: Int, header: Bool, striped: Bool = false) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(text)
            .font(.system(size: fontSize, weight: header ? .semibold : .regular))
            .multilineTextAlignment(textAlignment(alignment))
            .frame(minWidth: 60, maxWidth: 360, alignment: frameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(horizontalAlignment(alignment))
            .background(header ? AnyShapeStyle(.background.secondary) : striped ? AnyShapeStyle(.background.secondary.opacity(0.4)) : AnyShapeStyle(.clear))
            .overlay(Rectangle().stroke(.separator, lineWidth: 0.5))
    }

    private func frameAlignment(_ a: MarkdownTable.Alignment) -> Alignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func horizontalAlignment(_ a: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ a: MarkdownTable.Alignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A full-screen reader for a quiz's source material.
struct MarkdownReaderView: View {
    let title: String
    let markdown: String
    /// The original web page, opened in an in-app browser from the toolbar.
    var sourceURL: URL?
    /// Shown above the text, for example when a saved copy stands in for a missing file.
    var notice: String?

    @State private var showingPage = false

    var body: some View {
        ScrollView {
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding([.horizontal, .top])
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("reader.notice")
            }
            MarkdownView(markdown: markdown)
                .textSelection(.enabled)
                .frame(maxWidth: 820, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.content")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if sourceURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPage = true
                    } label: {
                        Label("Original page", systemImage: "safari")
                    }
                    .accessibilityIdentifier("reader.originalPage")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: markdown, subject: Text(title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("reader.share")
            }
        }
        .sheet(isPresented: $showingPage) {
            if let sourceURL {
                SafariView(url: sourceURL)
                    .ignoresSafeArea()
            }
        }
    }
}
