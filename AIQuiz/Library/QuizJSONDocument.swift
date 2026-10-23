import SwiftUI
import UniformTypeIdentifiers

/// A quiz JSON file for `fileExporter` (SPEC §2, F-4).
struct QuizJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// A file name without characters Files rejects.
    static func fileName(for quizName: String) -> String {
        let cleaned = quizName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Quiz" : cleaned
    }
}
