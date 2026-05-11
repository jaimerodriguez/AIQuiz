import Foundation
import SwiftData

actor FileImportService {
    static let shared = FileImportService()

    enum ImportError: LocalizedError {
        case accessDenied(URL)
        case decodingFailed(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let url):
                return "Couldn't open \(url.lastPathComponent)."
            case .decodingFailed(let url, let underlying):
                return "\(url.lastPathComponent): \(underlying.localizedDescription)"
            }
        }
    }

    @MainActor
    func importJSONFiles(_ urls: [URL], into context: ModelContext) async throws {
        var firstError: Error?
        for url in urls {
            do {
                try await importOne(url, into: context)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        try context.save()
        if let firstError { throw firstError }
    }

    @MainActor
    private func importOne(_ url: URL, into context: ModelContext) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.accessDenied(url)
        }

        let payload: QuizPayload
        do {
            payload = try QuizDecoder.decode(data)
        } catch {
            throw ImportError.decodingFailed(url, underlying: error)
        }

        let bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let record = QuizRecord(name: payload.name, sourceBookmark: bookmark)
        for (idx, card) in payload.cards.enumerated() {
            let cr = CardRecord(
                prompt: card.prompt,
                longAnswer: card.longAnswer,
                shortAnswer: card.shortAnswer,
                hint: card.hint,
                orderIndex: idx
            )
            cr.quiz = record
            record.cards.append(cr)
        }
        context.insert(record)
    }

    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return url
    }
}
