import Foundation
import LLMKit

/// SPEC F-20 / CR-006. Writes Markdown study notes for a topic, a source, or an existing deck.
public enum StudyNotesWriter {
    public static let label = "notes"

    public enum Input: Sendable {
        /// Notes on a topic, shaped by the topic options (level, language, focus...).
        case topic(QuizGenRequest)
        /// Notes summarising the request's `sourceContent`, faithful to it.
        case source(QuizGenRequest)
        /// Notes that teach what an existing deck tests (quizzes that have no notes yet).
        case cards(quizName: String, cards: [CardPayload])
    }

    static func request(for input: Input) -> ChatRequest {
        let user: String
        switch input {
        case .topic(let req): user = PromptBuilder.notesUser(topic: req)
        case .source(let req): user = PromptBuilder.notesUser(source: req)
        case .cards(let name, let cards): user = PromptBuilder.notesUser(quizName: name, cards: cards)
        }
        return ChatRequest(
            system: PromptBuilder.notesSystem(),
            messages: [.user(user)],
            maxTokens: 12_000,
            effort: .medium,
            timeout: 300,
            label: label
        )
    }

    /// Streams the notes; `onProgress` receives the running word count.
    public static func write(
        _ input: Input,
        using client: LLMClient,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> String {
        let request = request(for: input)
        try ContextBudget.check(
            system: request.system,
            user: request.messages.map(\.text).joined(),
            contextWindow: client.endpoint.contextWindowTokens
        )
        var text = ""
        var lastReported = 0
        for try await event in client.stream(request) {
            switch event {
            case .textDelta(let delta):
                text += delta
                let words = wordCount(text)
                if words - lastReported >= 10 {
                    lastReported = words
                    onProgress?(words)
                }
            case .done(let response):
                text = response.text.isEmpty ? text : response.text
            }
        }
        let notes = clean(text)
        guard wordCount(notes) >= 30 else {
            throw LLMError.malformedResponse("the study notes came back empty")
        }
        onProgress?(wordCount(notes))
        return notes
    }

    /// Removes a code fence wrapped around the whole document and surrounding whitespace.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// What the quiz creation pipeline is doing, for the progress display.
public enum QuizCreationPhase: Sendable, Equatable {
    case writingNotes(words: Int)
    case writingCards
}

/// SPEC F-20 / CR-006: optionally write study notes, then generate cards that draw on them.
public enum QuizCreationPipeline {
    /// - Parameters:
    ///   - notesClient: nil skips the notes step (the "Write study notes" toggle is off).
    /// - Returns: the quiz, with `studyNotes` set when notes were written.
    public static func run(
        _ request: QuizGenRequest,
        notesClient: LLMClient?,
        cardsClient: LLMClient,
        progress: @escaping @Sendable (QuizCreationPhase) -> Void = { _ in }
    ) async throws -> QuizPayload {
        var req = request
        var notes: String?

        if let notesClient {
            progress(.writingNotes(words: 0))
            let input: StudyNotesWriter.Input = request.source == .topic ? .topic(request) : .source(request)
            notes = try await StudyNotesWriter.write(input, using: notesClient) { words in
                progress(.writingNotes(words: words))
            }
            req.studyNotes = notes

            // Source plus notes may not fit; the notes alone then carry the content (SPEC F-20).
            if req.sourceContent != nil {
                let task = QuizGenerator.task(for: req)
                do {
                    try ContextBudget.check(system: task.system, user: task.user, contextWindow: cardsClient.endpoint.contextWindowTokens)
                } catch {
                    req.sourceContent = nil
                }
            }
        }

        progress(.writingCards)
        var payload = try await QuizGenerator.generate(req, using: cardsClient)
        payload.studyNotes = notes
        return payload
    }
}
