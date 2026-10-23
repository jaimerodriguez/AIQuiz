import Foundation
import AIQuizCore
import SwiftData

/// Imports quiz JSON files picked in Files (SPEC §2, D-4). Every file is tried; the first
/// problem is reported with the file's name, and good files are still imported.
@MainActor
enum QuizImporter {
    enum ImportError: LocalizedError {
        case accessDenied(URL)
        case invalid(URL, reason: String)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let url):
                return "Couldn't open \(url.lastPathComponent)."
            case .invalid(let url, let reason):
                return "\(url.lastPathComponent): \(reason)"
            }
        }
    }

    /// Imports every readable file and returns the new quizzes. Throws the first error after
    /// saving the ones that worked.
    @discardableResult
    static func importFiles(_ urls: [URL], into context: ModelContext) throws -> [QuizRecord] {
        var firstError: Error?
        var imported: [QuizRecord] = []
        for url in urls {
            do {
                let record = try makeRecord(from: url)
                context.insert(record)
                imported.append(record)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        try context.save()
        if let firstError { throw firstError }
        return imported
    }

    static func makeRecord(from url: URL) throws -> QuizRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.accessDenied(url)
        }
        let payload = try decode(data, from: url)
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return QuizRecord.make(from: payload, origin: .imported, sourceBookmark: bookmark)
    }

    static func decode(_ data: Data, from url: URL) throws -> QuizPayload {
        do {
            return try QuizDecoder.decode(data)
        } catch let error as CardValidationError {
            throw ImportError.invalid(url, reason: error.localizedDescription)
        } catch let error as DecodingError {
            throw ImportError.invalid(url, reason: describe(error))
        } catch {
            throw ImportError.invalid(url, reason: error.localizedDescription)
        }
    }

    /// A one-line reason for a malformed file (D-4), without Swift type names.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath
                .map { $0.intValue.map { "card \($0 + 1)" } ?? $0.stringValue }
                .drop { $0 == "quiz" }
            return keys.isEmpty ? "" : " (at \(keys.joined(separator: " › ")))"
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\"\(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "a value has the wrong type\(path(context))."
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "this is not valid quiz JSON." : "\(context.debugDescription)\(path(context))"
        @unknown default:
            return "this is not valid quiz JSON."
        }
    }
}
