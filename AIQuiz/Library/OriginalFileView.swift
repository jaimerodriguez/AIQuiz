import SwiftUI
import SafariServices

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

/// The original web page, inside the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
