import Foundation
import Synchronization
import Testing
import LLMKit
@testable import AIQuizCore

@Suite("Tutor chat (F-30, §9.1)")
@MainActor
struct TutorChatTests {
    private let card = CardPayload(prompt: "What is ATP?", longAnswer: "The cell's energy currency.", shortAnswer: "Energy currency")

    @Test("a reply streams into the transcript and the request carries the context")
    func streams() async throws {
        let recorder = RequestRecorder()
        let client = FakeLLMClient(streamChunkSize: 4, recorder: recorder) { _ in "ATP stores energy in phosphate bonds." }
        let chat = TutorChat(context: TutorContext(quizName: "Biology", description: "Cells", studyNotes: "Notes about mitochondria.", card: card))
        await chat.send("Explain this card", using: client)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        #expect(chat.messages[1].text == "ATP stores energy in phosphate bonds.")
        #expect(!chat.isStreaming)
        let request = try #require(recorder.requests.first)
        #expect(request.label == "tutor")
        #expect(request.responseFormat == nil)
        #expect(request.system.contains("Quiz: Biology"))
        #expect(request.system.contains("About the quiz: Cells"))
        #expect(request.system.contains("Notes about mitochondria."))
        #expect(request.system.contains("Prompt: What is ATP?"))
        #expect(request.messages.map(\.text) == ["Explain this card"])
    }

    @Test("deltas arrive one by one while streaming")
    func partialDeltas() async {
        let gate = AsyncGate()
        let client = SlowStreamClient(pieces: ["One ", "two ", "three"], gate: gate)
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        let sending = Task { await chat.send("Hi", using: client) }
        await waitUntil { chat.messages.last?.text == "One " }
        #expect(chat.isStreaming)
        #expect(chat.messages.last?.text == "One ")
        gate.open()
        await sending.value
        #expect(chat.messages.last?.text == "One two three")
    }

    @Test("follow-up turns send the earlier conversation")
    func history() async throws {
        let recorder = RequestRecorder()
        let client = FakeLLMClient(recorder: recorder) { request in "Reply \(request.messages.count)" }
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        await chat.send("First", using: client)
        await chat.send("Second", using: client)
        let last = try #require(recorder.requests.last)
        #expect(last.messages.map(\.text) == ["First", "Reply 1", "Second"])
        #expect(last.messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test("long history is trimmed to the token budget and still starts with the learner")
    func budget() async throws {
        let long = String(repeating: "word ", count: 6_000)  // ~7 500 tokens
        let recorder = RequestRecorder()
        let client = FakeLLMClient(recorder: recorder) { _ in long }
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        await chat.send("One", using: client)
        await chat.send("Two", using: client)
        await chat.send("Three", using: client)
        let last = try #require(recorder.requests.last)
        let historyTokens = last.messages.reduce(0) { $0 + ($1.text.utf8.count + 3) / 4 }
        #expect(historyTokens <= TutorChat.historyTokenBudget)
        #expect(last.messages.first?.role == .user)
        #expect(last.messages.last?.text == "Three")
        #expect(last.messages.count < 5, "the oldest turns were dropped")
    }

    @Test("study notes are cut to 4 000 tokens at a word boundary")
    func notesCap() {
        let notes = String(repeating: "mitochondria ", count: 3_000)  // 39 000 characters
        let context = TutorContext(quizName: "Q", studyNotes: notes)
        let kept = context.studyNotes ?? ""
        #expect(kept.count <= TutorContext.notesTokenLimit * 4 + 2)
        #expect(kept.hasSuffix(" …"))
        #expect(!kept.contains("mitochondri …"), "no word is cut in half")
        #expect(TutorContext(quizName: "Q", studyNotes: "short").studyNotes == "short")
    }

    @Test("a failed reply shows the error and leaves no empty message")
    func failure() async {
        let client = FakeLLMClient.scripted([.failure(.server(status: 503))])
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        await chat.send("Hi", using: client)
        #expect(chat.messages.map(\.role) == [.user])
        #expect(chat.error != nil)
        #expect(!chat.canMakeCards)
    }

    @Test("stop keeps what arrived and shows no error")
    func stop() async {
        let gate = AsyncGate()
        let client = SlowStreamClient(pieces: ["Partial ", "rest"], gate: gate)
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        let sending = Task { await chat.send("Hi", using: client) }
        await waitUntil { chat.messages.last?.text == "Partial " }
        chat.stop()
        await sending.value
        #expect(chat.messages.last?.text == "Partial ")
        #expect(chat.error == nil)
        #expect(!chat.isStreaming)
    }

    @Test("empty messages and sends during a reply are ignored")
    func ignoresEmpty() async {
        let recorder = RequestRecorder()
        let client = FakeLLMClient(recorder: recorder) { _ in "OK" }
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        await chat.send("   ", using: client)
        #expect(chat.messages.isEmpty)
        #expect(recorder.count == 0)
    }

    @Test("starters depend on whether a card is open")
    func starters() {
        #expect(TutorChat(context: TutorContext(quizName: "Q", card: card)).starters.first == "Explain this card")
        #expect(TutorChat(context: TutorContext(quizName: "Q")).starters.first == "Explain the key ideas")
    }

    @Test("Make cards sends the transcript through F-27's contract")
    func makeCards() async throws {
        let recorder = RequestRecorder()
        let cardsJSON = #"{"cards":[{"prompt":"New one?","long_answer":"Because.","short_answer":null,"hint":null},{"prompt":"New two?","long_answer":"Also because.","short_answer":null,"hint":null},{"prompt":"New three?","long_answer":"Again because.","short_answer":null,"hint":null}]}"#
        let client = FakeLLMClient(recorder: recorder) { request in
            request.responseFormat == nil ? "ATP is energy." : cardsJSON
        }
        let chat = TutorChat(context: TutorContext(quizName: "Biology"))
        await #expect(throws: LLMError.self) { try await chat.makeCards(existingPrompts: [], using: client) }
        await chat.send("What is ATP?", using: client)
        #expect(chat.canMakeCards)
        let cards = try await chat.makeCards(existingPrompts: ["Old prompt"], using: client)
        #expect(cards.map(\.prompt) == ["New one?", "New two?", "New three?"])
        let request = try #require(recorder.requests.last)
        #expect(request.responseFormat?.name == "chatCards")
        #expect(request.messages[0].text.contains("Learner: What is ATP?"))
        #expect(request.messages[0].text.contains("Tutor: ATP is energy."))
        #expect(request.messages[0].text.contains("- Old prompt"))
    }

    @Test("Make cards retries once when a card breaks the rules")
    func makeCardsRetry() async throws {
        let bad = #"{"cards":[{"prompt":"","long_answer":"x","short_answer":null,"hint":null}]}"#
        let good = #"{"cards":[{"prompt":"Fine?","long_answer":"Yes.","short_answer":null,"hint":null}]}"#
        let counter = Counter()
        let client = FakeLLMClient { request in
            if request.responseFormat == nil { return "Reply" }
            return counter.next() == 0 ? bad : good
        }
        let chat = TutorChat(context: TutorContext(quizName: "Q"))
        await chat.send("Hi", using: client)
        let cards = try await chat.makeCards(existingPrompts: [], using: client)
        #expect(cards.map(\.prompt) == ["Fine?"])
        #expect(counter.next() == 2, "one bad answer, one retry")
    }
}

/// Counts calls across the fake client's concurrent handler.
final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { v in defer { v += 1 }; return v } }
}

/// Holds a stream between its first piece and the rest until `open()`.
final class AsyncGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// A client that streams its first piece, waits for the gate, then streams the rest.
struct SlowStreamClient: LLMClient {
    let pieces: [String]
    let gate: AsyncGate
    var endpoint: LLMEndpoint { .fake() }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        ChatResponse(text: pieces.joined())
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let pieces = pieces
        let gate = gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, piece) in pieces.enumerated() {
                    if index == 1 { await gate.wait() }
                    if Task.isCancelled {
                        continuation.finish(throwing: LLMError.cancelled)
                        return
                    }
                    continuation.yield(.textDelta(piece))
                }
                continuation.yield(.done(ChatResponse(text: pieces.joined())))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                gate.open()
            }
        }
    }

    func listModels() async throws -> [String] { [] }
}
