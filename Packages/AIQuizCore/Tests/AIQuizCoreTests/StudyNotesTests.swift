import Foundation
import Synchronization
import Testing
import LLMKit
@testable import AIQuizCore

private let sampleNotes = """
Augustus founded the empire and set the pattern later emperors followed.

## The Julio-Claudians
- **Augustus** ruled 27 BC to 14 AD.
- **Tiberius**, his stepson, followed and later withdrew to Capri.

## Why it matters
The succession was never formally defined, which caused repeated crises.
"""

private let validQuiz = """
{"quiz":{"name":"Rome","cards":[{"prompt":"Who was first?","long_answer":"Augustus.","short_answer":"Augustus","hint":null}]}}
"""

@Suite("StudyNotesWriter")
struct StudyNotesWriterTests {
    @Test("topic notes: Markdown prompt, streamed, labelled, progress reported")
    func topicNotes() async throws {
        let client = FakeLLMClient(streamChunkSize: 5) { _ in sampleNotes }
        let words = Mutex<[Int]>([])
        let req = QuizGenRequest(source: .topic, topic: "Roman emperors", cardCount: 12, difficulty: "intro", language: "en", focus: "succession")
        let notes = try await StudyNotesWriter.write(.topic(req), using: client) { w in words.withLock { $0.append(w) } }

        #expect(notes == sampleNotes)
        let sent = try #require(client.recorder.requests.first)
        #expect(sent.label == "notes")
        #expect(sent.responseFormat == nil)
        #expect(sent.effort == .medium)
        #expect(sent.system.contains("Markdown"))
        #expect(sent.messages[0].text.contains("Topic: Roman emperors"))
        #expect(sent.messages[0].text.contains("Focus on: succession"))
        #expect(sent.messages[0].text.contains("12-card quiz"))
        let reported = words.withLock { $0 }
        #expect(reported.last == StudyNotesWriter.wordCount(sampleNotes))
    }

    @Test("source notes embed the source and ask for faithfulness")
    func sourceNotes() async throws {
        let client = FakeLLMClient { _ in sampleNotes }
        let req = QuizGenRequest(source: .article, topic: "t", sourceContent: "ARTICLE BODY")
        _ = try await StudyNotesWriter.write(.source(req), using: client)
        let user = try #require(client.recorder.requests.first).messages[0].text
        #expect(user.contains("---SOURCE---\nARTICLE BODY\n---END-SOURCE---"))
        #expect(user.contains("do not add facts"))
        #expect(user.contains("article"))
    }

    @Test("deck notes list every card")
    func cardNotes() async throws {
        let client = FakeLLMClient { _ in sampleNotes }
        let cards = [CardPayload(prompt: "Q1", longAnswer: "A1", shortAnswer: "S1"), CardPayload(prompt: "Q2", longAnswer: "A2")]
        _ = try await StudyNotesWriter.write(.cards(quizName: "Deck", cards: cards), using: client)
        let user = try #require(client.recorder.requests.first).messages[0].text
        #expect(user.contains("\"Deck\""))
        #expect(user.contains("1. Q: Q1\n   A: A1 (short: S1)"))
        #expect(user.contains("2. Q: Q2\n   A: A2"))
    }

    @Test("a code fence around the whole document is removed")
    func fenceRemoval() {
        #expect(StudyNotesWriter.clean("```markdown\n## Title\nBody\n```\n") == "## Title\nBody")
        #expect(StudyNotesWriter.clean("  ## Title  \n") == "## Title")
    }

    @Test("near-empty notes are an error")
    func emptyNotes() async {
        let client = FakeLLMClient { _ in "Sure." }
        await #expect(throws: LLMError.self) {
            _ = try await StudyNotesWriter.write(.topic(QuizGenRequest(source: .topic, topic: "x")), using: client)
        }
    }

    @Test("source over the context budget is rejected before sending")
    func budget() async {
        let small = LLMEndpoint(kind: .fake, name: "Small", model: "m", contextWindowTokens: 2_048)
        let client = FakeLLMClient(endpoint: small) { _ in sampleNotes }
        let req = QuizGenRequest(source: .markdown, topic: "t", sourceContent: String(repeating: "word ", count: 3_000))
        await #expect(throws: LLMError.contextTooLong) {
            _ = try await StudyNotesWriter.write(.source(req), using: client)
        }
        #expect(client.recorder.count == 0)
    }
}

@Suite("QuizCreationPipeline")
struct QuizCreationPipelineTests {
    @Test("notes first, then cards drawn from them; notes attached to the quiz")
    func notesThenCards() async throws {
        let recorder = RequestRecorder()
        let client = FakeLLMClient(recorder: recorder) { request in
            request.label == "notes" ? sampleNotes : validQuiz
        }
        let phases = Mutex<[QuizCreationPhase]>([])
        let quiz = try await QuizCreationPipeline.run(
            QuizGenRequest(source: .topic, topic: "Rome", cardCount: 10),
            notesClient: client,
            cardsClient: client
        ) { p in phases.withLock { $0.append(p) } }

        #expect(quiz.studyNotes == sampleNotes)
        #expect(quiz.cards.count == 1)
        let labels = recorder.requests.map(\.label)
        #expect(labels == ["notes", "quiz"])
        let cardsPrompt = recorder.requests[1].messages[0].text
        #expect(cardsPrompt.contains("---STUDY-NOTES---"))
        #expect(cardsPrompt.contains("Every card must be answerable from them"))
        let seen = phases.withLock { $0 }
        #expect(seen.first == .writingNotes(words: 0))
        #expect(seen.last == .writingCards)
    }

    @Test("notes can be skipped")
    func skipNotes() async throws {
        let client = FakeLLMClient { _ in validQuiz }
        let quiz = try await QuizCreationPipeline.run(QuizGenRequest(source: .topic, topic: "Rome"), notesClient: nil, cardsClient: client)
        #expect(quiz.studyNotes == nil)
        #expect(client.recorder.requests.map(\.label) == ["quiz"])
        #expect(!client.recorder.requests[0].messages[0].text.contains("STUDY-NOTES"))
    }

    @Test("when source plus notes don't fit, cards come from the notes alone")
    func dropSourceWhenTooBig() async throws {
        let mid = LLMEndpoint(kind: .fake, name: "Mid", model: "m", contextWindowTokens: 6_000)
        let notesClient = FakeLLMClient { _ in sampleNotes }
        let cardsClient = FakeLLMClient(endpoint: mid) { _ in validQuiz }
        let source = String(repeating: "fact ", count: 4_000)
        let quiz = try await QuizCreationPipeline.run(
            QuizGenRequest(source: .markdown, topic: "t", sourceContent: source),
            notesClient: notesClient,
            cardsClient: cardsClient
        )
        #expect(quiz.studyNotes == sampleNotes)
        let prompt = cardsClient.recorder.requests[0].messages[0].text
        #expect(!prompt.contains("SOURCE-MARKDOWN"))
        #expect(prompt.contains("Read the following study notes"))
    }
}

@Suite("Quiz JSON study_notes")
struct QuizPayloadNotesTests {
    @Test("study_notes round-trips and both key styles decode")
    func roundTrip() throws {
        let payload = QuizPayload(name: "N", cards: [CardPayload(prompt: "p", longAnswer: "l")], studyNotes: "## Notes\nBody")
        let data = try QuizDecoder.encode(payload)
        #expect(String(decoding: data, as: UTF8.self).contains("\"study_notes\""))
        #expect(try QuizDecoder.decode(data) == payload)

        let hyphen = #"{"quiz":{"name":"N","study-notes":"x y","cards":[{"prompt":"p","long_answer":"l"}]}}"#
        #expect(try QuizDecoder.decode(Data(hyphen.utf8)).studyNotes == "x y")
    }

    @Test("absent or blank notes decode as nil and are not written")
    func absent() throws {
        let blank = #"{"quiz":{"name":"N","study_notes":"  ","cards":[{"prompt":"p","long_answer":"l"}]}}"#
        #expect(try QuizDecoder.decode(Data(blank.utf8)).studyNotes == nil)
        let data = try QuizDecoder.encode(QuizPayload(name: "N", cards: []))
        #expect(!String(decoding: data, as: UTF8.self).contains("study_notes"))
    }
}

@Suite("MarkdownParser")
struct MarkdownParserTests {
    @Test("headings, paragraphs with soft breaks, bullet and numbered lists")
    func basics() {
        let md = """
        # Title
        First line
        continues here.

        ## Section ##
        - one
        - **two**
          - nested
        1. first
        2) second
        """
        #expect(MarkdownParser.parse(md) == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line continues here."),
            .heading(level: 2, text: "Section"),
            .bulletList([
                MarkdownListItem(depth: 0, text: "one"),
                MarkdownListItem(depth: 0, text: "**two**"),
                MarkdownListItem(depth: 1, text: "nested")
            ]),
            .numberedList([
                MarkdownListItem(depth: 0, text: "first", number: 1),
                MarkdownListItem(depth: 0, text: "second", number: 2)
            ])
        ])
    }

    @Test("quotes, rules and fenced code kept verbatim")
    func quoteRuleCode() {
        let md = "> quoted\n> more\n\n---\n\n```swift\nlet x = 1\n  // indented\n```\n"
        #expect(MarkdownParser.parse(md) == [
            .quote("quoted more"),
            .rule,
            .code("let x = 1\n  // indented")
        ])
    }

    @Test("list item continuation lines join the item")
    func continuation() {
        #expect(MarkdownParser.parse("- a long item\n  that wraps\n- next") == [
            .bulletList([MarkdownListItem(depth: 0, text: "a long item that wraps"), MarkdownListItem(depth: 0, text: "next")])
        ])
    }

    @Test("not a heading or list without a space; CRLF handled; unterminated fence kept")
    func edgeCases() {
        #expect(MarkdownParser.parse("#hashtag\r\n-dash\r\n") == [.paragraph("#hashtag -dash")])
        #expect(MarkdownParser.parse("```\ncode") == [.code("code")])
        #expect(MarkdownParser.parse("") == [])
    }

    @Test("a bullet list directly after a numbered list starts a new list")
    func listSwitch() {
        #expect(MarkdownParser.parse("1. a\n- b") == [
            .numberedList([MarkdownListItem(depth: 0, text: "a", number: 1)]),
            .bulletList([MarkdownListItem(depth: 0, text: "b")])
        ])
    }

    @Test("the sample study notes parse into the expected outline")
    func sample() {
        let blocks = MarkdownParser.parse(sampleNotes)
        #expect(blocks.count == 5)
        #expect(blocks[1] == .heading(level: 2, text: "The Julio-Claudians"))
        if case .bulletList(let items) = blocks[2] { #expect(items.count == 2) } else { Issue.record("expected list") }
    }
}
