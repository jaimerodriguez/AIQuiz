import SwiftUI
import SafariServices
import PDFKit

/// Reads the Markdown file a quiz was generated from, through the bookmark saved at generation
/// time (CR-007). Falls back to the copy saved with the quiz when the file can't be opened.
enum OriginalFileLoader {
    enum Outcome: Equatable {
        /// The current contents of the original file.
        case original(String)
        /// The copy saved at generation time, with the reason the original wasn't used.
        case savedCopy(String, reason: String)
        case unavailable(String)
    }

    /// A bookmark for a file picked in Files, taken while its security scope is open.
    static func bookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func load(bookmark: Data?, savedCopy: String?) async -> Outcome {
        let failure: String
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                do {
                    return .original(try await ContentExtractor.loadMarkdown(url))
                } catch {
                    failure = "The original file couldn't be read, so this is the copy saved when the quiz was made."
                }
            } else {
                failure = "The original file was moved or deleted, so this is the copy saved when the quiz was made."
            }
        } else {
            failure = "There's no link to the original file, so this is the copy saved when the quiz was made."
        }
        if let savedCopy {
            return .savedCopy(savedCopy, reason: failure)
        }
        return .unavailable("The original file can't be opened and no copy was saved.")
    }
}

struct OriginalFileView: View {
    let title: String
    let bookmark: Data?
    let savedCopy: String?

    @State private var outcome: OriginalFileLoader.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case nil:
                ProgressView()
            case .original(let text):
                MarkdownReaderView(title: title, markdown: text)
            case .savedCopy(let text, let reason):
                MarkdownReaderView(title: title, markdown: text, notice: reason)
            case .unavailable(let message):
                ContentUnavailableView(title, systemImage: "doc.questionmark", description: Text(message))
            }
        }
        .task {
            outcome = await OriginalFileLoader.load(bookmark: bookmark, savedCopy: savedCopy)
        }
    }
}

/// "Read Source Materials" (CR-008): the content a quiz was generated from, in its own form.
struct SourceMaterialsView: View {
    let quiz: QuizRecord

    var body: some View {
        switch quiz.sourceKind {
        case .markdownFile?:
            OriginalFileView(title: quiz.sourceTitle ?? "Markdown file", bookmark: quiz.sourceBookmark, savedCopy: quiz.sourceText)
        case .webPage?:
            if let text = quiz.sourceText {
                MarkdownReaderView(
                    title: quiz.sourceTitle ?? "Web page",
                    markdown: text,
                    sourceURL: quiz.sourceURL,
                    notice: "Text saved from the page when the quiz was made. Tap the Safari button to open the original page."
                )
            } else if let url = quiz.sourceURL {
                SafariView(url: url).ignoresSafeArea()
            } else {
                ContentUnavailableView("Source unavailable", systemImage: "doc.questionmark")
            }
        case .pastedText?:
            MarkdownReaderView(title: "Source text", markdown: quiz.sourceText ?? "")
        case .pdfFile?:
            PDFSourceView(title: quiz.sourceTitle ?? "PDF", bookmark: quiz.sourceBookmark, savedText: quiz.sourceText)
        case .scannedPages?:
            MarkdownReaderView(title: "Scanned text", markdown: quiz.sourceText ?? "", notice: "The text recognised from your photos when the quiz was made.")
        case nil:
            ContentUnavailableView("No source materials", systemImage: "doc.questionmark",
                                   description: Text("This quiz was generated from a topic, not a source."))
        }
    }
}

/// The original web page, inside the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A quiz's PDF, shown as itself through its bookmark; the saved text stands in when the
/// file can't be opened (Phase 5).
struct PDFSourceView: View {
    let title: String
    let bookmark: Data?
    let savedText: String?
    @State private var document: PDFDocument?
    @State private var scopedURL: URL?
    @State private var loaded = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("reader.pdf")
            } else if loaded {
                MarkdownReaderView(title: title, markdown: savedText ?? "",
                                   notice: "The PDF couldn't be opened, so this is the text saved when the quiz was made.")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { open() }
        .onDisappear { scopedURL?.stopAccessingSecurityScopedResource() }
    }

    private func open() {
        defer { loaded = true }
        guard document == nil, let bookmark else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        document = PDFDocument(url: url)
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
