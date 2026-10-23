import SwiftUI
import AIQuizCore

/// Renders Markdown (pasted text, Markdown files, saved page text) natively at the user's
/// reading size (DECISIONS ADR-013).
/// Blocks come from `MarkdownParser`; inline bold, italics and code use `AttributedString(markdown:)`.
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
            Text(Self.inline(text))
                .font(.system(size: headingSize(level, typo), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? typo.bodyPoints * 0.4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(typo.bodyFont)
        case .bulletList(let items):
            listView(items, typo: typo) { item in item.depth == 0 ? "•" : "◦" }
        case .numberedList(let items):
            listView(items, typo: typo) { item in "\(item.number ?? 1)." }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tint.opacity(0.6))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(typo.bodyFont)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(size: typo.captionPoints, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func listView(
        _ items: [MarkdownListItem],
        typo: QuizFontSize,
        marker: @escaping (MarkdownListItem) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: typo.bodyPoints * 0.3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(item))
                        .font(typo.bodyFont)
                        .foregroundStyle(.secondary)
                    Text(Self.inline(item.text))
                        .font(typo.bodyFont)
                }
                .padding(.leading, CGFloat(item.depth) * typo.bodyPoints)
            }
        }
    }

    private func headingSize(_ level: Int, _ typo: QuizFontSize) -> CGFloat {
        switch level {
        case 1: return typo.promptPoints * 0.85
        case 2: return typo.emphasisPoints
        default: return typo.bodyPoints + 2
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A full-screen reader for a quiz's original content.
struct MarkdownReaderView: View {
    let title: String
    let markdown: String
    var sourceURL: URL?
    /// Shown above the text, for example when a saved copy stands in for a missing file.
    var notice: String?

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
            if let sourceURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: sourceURL) {
                        Label("Open original page", systemImage: "safari")
                    }
                    .accessibilityIdentifier("reader.openOriginal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: markdown, subject: Text(title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("reader.share")
            }
        }
    }
}
