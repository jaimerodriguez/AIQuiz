import SwiftUI
import UniformTypeIdentifiers

/// A quiz file for `fileExporter`: JSON (SPEC §2, F-4) or an Anki package (F-62).
struct QuizFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .ankiPackage]
    static let writableContentTypes: [UTType] = [.json, .ankiPackage]
    var data: Data
    var contentType: UTType = .json

    init(data: Data, contentType: UTType = .json) {
        self.data = data
        self.contentType = contentType
    }

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
