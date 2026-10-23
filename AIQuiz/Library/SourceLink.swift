import Foundation
import SwiftData
import UniformTypeIdentifiers

/// The file a quiz came from, through its security-scoped bookmark (SPEC F-5). Imported
/// JSON quizzes and quizzes generated from a Markdown file have one.
@MainActor
enum SourceLink {
    /// Quizzes whose source is a file in Files.
    static func hasFileSource(_ quiz: QuizRecord) -> Bool {
        quiz.sourceBookmark != nil && (quiz.origin == .imported || quiz.sourceKind == .markdownFile || quiz.sourceKind == .pdfFile)
    }

    /// True when the bookmark no longer leads to a readable file.
    nonisolated static func isMissing(bookmark: Data) -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return true
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return !FileManager.default.isReadableFile(atPath: url.path)
    }

    /// File types the picker offers when re-linking.
    static func contentTypes(for quiz: QuizRecord) -> [UTType] {
        if quiz.sourceKind == .markdownFile {
            return [.plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        }
        if quiz.sourceKind == .pdfFile { return [.pdf] }
        return [.json]
    }

    enum RelinkError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            if case .unreadable(let url) = self { return "Couldn't open \(url.lastPathComponent)." }
            return nil
        }
    }

    /// Points the quiz at a new file (*Re-link file*). The cards are not changed.
    static func relink(_ quiz: QuizRecord, to url: URL) throws {
        guard let bookmark = OriginalFileLoader.bookmark(for: url) else { throw RelinkError.unreadable(url) }
        quiz.sourceBookmark = bookmark
        if quiz.sourceKind == .markdownFile || quiz.sourceKind == .pdfFile {
            quiz.sourceTitle = url.lastPathComponent
        }
        try quiz.modelContext?.save()
        Log.data.info("Re-linked a quiz to \(url.lastPathComponent)")
    }
}

/// Which visible quizzes have lost their source file, checked once per quiz and bookmark.
@MainActor
@Observable
final class SourceStatus {
    private(set) var missing: Set<UUID> = []
    private var checked: [UUID: Data] = [:]

    func isMissing(_ quiz: QuizRecord) -> Bool { missing.contains(quiz.id) }

    func check(_ quiz: QuizRecord) async {
        guard SourceLink.hasFileSource(quiz), let bookmark = quiz.sourceBookmark, checked[quiz.id] != bookmark else { return }
        checked[quiz.id] = bookmark
        let id = quiz.id
        let gone = await Task.detached(priority: .utility) { SourceLink.isMissing(bookmark: bookmark) }.value
        if gone { missing.insert(id) } else { missing.remove(id) }
    }
}
