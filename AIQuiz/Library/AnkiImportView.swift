import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AIQuizCore

extension UTType {
    /// Anki's deck and collection packages (Info.plist declares both).
    static let ankiPackage = UTType(importedAs: "net.ankiweb.apkg", conformingTo: .data)
    static let ankiCollection = UTType(importedAs: "net.ankiweb.colpkg", conformingTo: .data)

    static func isAnki(_ url: URL) -> Bool {
        ["apkg", "colpkg"].contains(url.pathExtension.lowercased())
    }

    /// What *Import Anki deck* lets you pick: any file. iOS may label an `.apkg` with another
    /// app's type, or a file provider (a browser's downloads folder) with a generic one, and a
    /// picker limited to AIQuiz's own types then greys it out (docs/anki.md A-13). The
    /// importer checks the content instead.
    static let ankiPickerTypes: [UTType] = [.ankiPackage, .ankiCollection, .zip, .data]
}

/// One Anki file to import, however it arrived: the + menu, *Open in AIQuiz*, or Share (F-62).
struct AnkiImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    /// A file from the document picker or *Open in*, read under its security scope.
    var securityScoped = false
    /// A copy that belongs to AIQuiz (Share, *Open in*'s Inbox), removed once read.
    var deleteAfter = false
    /// The folder the decks go into (F-63); nil is the top level.
    var folderID: UUID? = nil
}

/// Hands Anki files to the library, which shows the import sheet.
@Observable
@MainActor
final class AnkiImportRouter {
    var pending: AnkiImportRequest?

    func open(_ url: URL, securityScoped: Bool = false, deleteAfter: Bool = false, folderID: UUID? = nil) {
        pending = AnkiImportRequest(url: url, securityScoped: securityScoped, deleteAfter: deleteAfter, folderID: folderID)
    }
}

/// Anki packages in and out of the library (docs/anki-interchange.md).
@MainActor
enum AnkiLibrary {
    /// Saves each deck as a quiz tagged `anki`, with its cards' schedules and answer counts.
    /// Parent decks become folders under `folder` and the deck itself the quiz (F-63):
    /// "Spanish::Verbs" is a quiz "Verbs" in a folder "Spanish".
    @discardableResult
    static func save(_ result: AnkiImportResult, into context: ModelContext, folder: UUID? = nil) throws -> [QuizRecord] {
        var saved: [QuizRecord] = []
        for quiz in result.quizzes where !quiz.cards.isEmpty {
            let parent = try FolderStore.folderID(forPath: Array(quiz.path.dropLast()), under: folder, context: context)
            let record = QuizRecord.make(from: QuizPayload(name: quiz.path.last ?? quiz.name, tags: ["anki"], cards: quiz.cards.map(\.payload)), origin: .imported)
            record.folderID = parent
            for (card, imported) in zip(record.sortedCards, quiz.cards) {
                card.schedule = imported.schedule
                card.correctCount = imported.correct
                card.partialCount = imported.partial
                card.wrongCount = imported.wrong
                card.lastSeenAt = imported.schedule.lastReviewedAt
            }
            QuizStats.refresh(record)
            context.insert(record)
            saved.append(record)
        }
        try context.save()
        return saved
    }

    /// The quiz as an `.apkg`, cards in deck order with their schedules. The deck is named
    /// with the folder path, so Anki shows it as nested decks (F-63).
    static func package(for quiz: QuizRecord) throws -> Data {
        let folders = quiz.modelContext.map { FolderStore.path(to: quiz.folderID, in: $0) } ?? []
        return try AnkiExporter.package(quizName: (folders + [quiz.name]).joined(separator: AnkiImporter.separator),
                                        cards: quiz.sortedCards.map { AnkiExporter.Card(payload: $0.payload, schedule: $0.schedule) })
    }
}

/// Reads an Anki file off the main actor, saves the quizzes, and shows what came in (F-62).
struct AnkiImportView: View {
    let request: AnkiImportRequest
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .reading

    enum Phase {
        case reading
        case done(AnkiImportResult, dueNow: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Reading the Anki deck…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("anki.reading")
                case .done(let result, let dueNow):
                    summary(result, dueNow: dueNow)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't import", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                    .accessibilityIdentifier("anki.error")
                }
            }
            .navigationTitle("Import from Anki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .primaryActionStyle()
                        .disabled({ if case .reading = phase { return true } else { return false } }())
                        .accessibilityIdentifier("anki.done")
                }
            }
        }
        .task { await run() }
        .interactiveDismissDisabled({ if case .reading = phase { return true } else { return false } }())
    }

    private func summary(_ result: AnkiImportResult, dueNow: Int) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AccentIcon(systemName: "square.and.arrow.down.on.square", size: 56)
                    Text(result.quizzes.count == 1 ? "1 quiz, \(result.cardCount) cards" : "\(result.quizzes.count) quizzes, \(result.cardCount) cards")
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("anki.summary")
                    if dueNow > 0 {
                        Text("\(dueNow) due now, from your Anki reviews")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("anki.due")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Quizzes") {
                ForEach(Array(result.quizzes.enumerated()), id: \.offset) { index, quiz in
                    LabeledContent(quiz.name) {
                        Text(verbatim: "\(quiz.cards.count)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("anki.quiz.\(index)")
                }
            }
            if result.skippedImages + result.skippedSounds + result.skippedCards > 0 {
                Section {
                    if result.skippedImages > 0 { skipped("photo", "\(result.skippedImages) image\(result.skippedImages == 1 ? "" : "s") left out") }
                    if result.skippedSounds > 0 { skipped("speaker.slash", "\(result.skippedSounds) sound\(result.skippedSounds == 1 ? "" : "s") left out") }
                    if result.skippedCards > 0 { skipped("rectangle.slash", "\(result.skippedCards) card\(result.skippedCards == 1 ? "" : "s") with nothing to show as text") }
                } footer: {
                    Text("AIQuiz cards are text only.")
                }
                .accessibilityIdentifier("anki.skipped")
            }
        }
    }

    /// Any file can be picked, so a file that isn't a package says what to pick instead.
    static func message(for error: Error) -> String {
        if let zip = error as? ZipArchive.Failure, zip == .notAZip {
            return "This isn't an Anki deck. Pick a .apkg or .colpkg file exported from Anki."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func skipped(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private func run() async {
        guard case .reading = phase else { return }
        let request = self.request
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let scoped = request.securityScoped && request.url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { request.url.stopAccessingSecurityScopedResource() }
                    if request.deleteAfter { try? FileManager.default.removeItem(at: request.url) }
                }
                return try AnkiImporter.importPackage(at: request.url)
            }.value
            guard result.cardCount > 0 else {
                phase = .failed("There are no cards AIQuiz can show in this deck.")
                return
            }
            let saved = try AnkiLibrary.save(result, into: context, folder: request.folderID)
            let reviewsDue = saved.flatMap(\.cards).filter { !$0.isNewCard && ($0.dueAt ?? .distantFuture) <= .now }.count
            phase = .done(result, dueNow: reviewsDue)
            Log.data.info("Anki import: \(result.quizzes.count) quizzes, \(result.cardCount) cards (\(result.format.rawValue))")
        } catch {
            phase = .failed(Self.message(for: error))
            Log.data.error("Anki import failed: \(String(describing: error))")
        }
    }
}
