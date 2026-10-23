import Foundation
import Synchronization
import Testing
import LLMKit
@testable import AIQuizCore

/// Reader mode on six hand-written pages modelled on real layouts (PLAN Phase 5 tests).
private let para = String(repeating: "The empire grew through careful administration and long roads. ", count: 3)

private let wikipedia = """
<html><head><title>Tiberius - Wikipedia</title></head><body>
<div id="mw-navigation"><ul><li>Main page</li><li>Contents</li></ul></div>
<div class="mw-body"><h1 id="firstHeading">Tiberius</h1>
<div id="mw-content-text" class="mw-parser-output">
<table class="infobox"><tr><td>Reign 14–37 AD</td></tr></table>
<p>Tiberius Julius Caesar Augustus was the second Roman emperor. \(para)</p>
<h2>Early life</h2><p>He was born in Rome in 42 BC. \(para)</p>
<div class="navbox">Roman emperors navigation box Augustus Caligula Claudius</div>
<p>Tiberius died in Misenum in 37 AD.</p></div></div>
<div id="footer">Text is available under a licence.</div></body></html>
"""

private let blog = """
<html><head><meta property="og:title" content="Why I study with flashcards"><title>Blog</title></head><body>
<header class="masthead"><a href="/">My blog</a></header>
<article><h1>Why I study with flashcards</h1><p>Flashcards make recall effortful, which is why they work. \(para)</p>
<ul><li>Short sessions every day</li><li>Say the answer out loud</li></ul>
<blockquote>Testing beats rereading.</blockquote><p>That is the whole trick.</p></article>
<aside class="sidebar">Subscribe to my newsletter</aside>
<div class="comments">Great post!</div></body></html>
"""

private let news = """
<html><head><title>City council approves new library</title></head><body>
<nav><a>World</a><a>Politics</a><a>Sport</a></nav>
<div class="cookie-banner">We use cookies</div>
<main><h1>City council approves new library</h1>
<div class="share-buttons">Share on social</div>
<p>The council voted on Tuesday to fund a new central library. \(para)</p>
<p>Construction starts next spring and should finish in two years.</p>
<div class="related-stories"><p>Related: Bridge reopens after repairs</p></div></main>
<footer>© News Corp</footer></body></html>
"""

private let paywall = """
<html><head><title>Premium story</title></head><body>
<article><h1>Premium story</h1><p>Subscribe to read the full article.</p></article></body></html>
"""

private let noArticle = """
<html><head><title>Index</title></head><body><nav><a>Home</a><a>About</a></nav><footer>Contact</footer></body></html>
"""

@Suite("Reader mode (F-21)")
struct ReaderModeTests {
    @Test("Wikipedia-like page: first and last paragraphs, no navigation, navbox or infobox")
    func wikipediaPage() throws {
        let article = try ReaderModeExtractor.extract(html: wikipedia)
        #expect(article.title == "Tiberius - Wikipedia")
        #expect(article.text.contains("Tiberius Julius Caesar Augustus was the second Roman emperor."))
        #expect(article.text.hasSuffix("Tiberius died in Misenum in 37 AD."))
        #expect(article.text.contains("## Early life"))
        #expect(!article.text.contains("Main page"))
        #expect(!article.text.contains("navigation box"))
        #expect(!article.text.contains("Reign 14"))
        #expect(!article.text.contains("licence"))
    }

    @Test("blog: the article with its list and quote, no sidebar or comments")
    func blogPage() throws {
        let article = try ReaderModeExtractor.extract(html: blog)
        #expect(article.title == "Why I study with flashcards", "og:title wins")
        #expect(article.text.hasPrefix("# Why I study with flashcards"))
        #expect(article.text.contains("- Short sessions every day"))
        #expect(article.text.contains("> Testing beats rereading."))
        #expect(article.text.hasSuffix("That is the whole trick."))
        #expect(!article.text.contains("newsletter"))
        #expect(!article.text.contains("Great post"))
    }

    @Test("news page: main content without nav, cookie banner, share buttons or related stories")
    func newsPage() throws {
        let article = try ReaderModeExtractor.extract(html: news)
        #expect(article.text.contains("The council voted on Tuesday"))
        #expect(article.text.hasSuffix("should finish in two years."))
        for noise in ["Politics", "cookies", "Share on social", "Bridge reopens", "News Corp"] {
            #expect(!article.text.contains(noise), "\(noise) should be gone")
        }
    }

    @Test("a paywall stub is too short")
    func paywallStub() {
        #expect(throws: ReaderModeExtractor.Failure.self) { _ = try ReaderModeExtractor.extract(html: paywall) }
        do {
            _ = try ReaderModeExtractor.extract(html: paywall)
        } catch let failure as ReaderModeExtractor.Failure {
            if case .tooShort = failure {} else { Issue.record("expected tooShort, got \(failure)") }
            #expect(failure.localizedDescription.contains("Paste the text instead"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("a page with no article fails")
    func noArticlePage() {
        #expect(throws: ReaderModeExtractor.Failure.self) { _ = try ReaderModeExtractor.extract(html: noArticle) }
    }

    @Test("a Windows-1252 page decodes from its meta charset, and the header wins when given")
    func nonUTF8() throws {
        let html = """
        <html><head><meta charset="windows-1252"><title>Café</title></head><body><article><h1>Crème brûlée</h1><p>Le café est très bon à Paris. \(para) \(para)</p></article></body></html>
        """
        let data = try #require(html.data(using: .windowsCP1252))
        #expect(String(data: data, encoding: .utf8) == nil, "the bytes are not valid UTF-8")
        let decoded = ReaderModeExtractor.decode(data, contentType: "text/html")
        let article = try ReaderModeExtractor.extract(html: decoded)
        #expect(article.text.contains("Crème brûlée"))
        #expect(article.text.contains("Le café est très bon"))
        #expect(ReaderModeExtractor.decode(data, contentType: "text/html; charset=windows-1252").contains("très"))
    }
}

@Suite("Chunker and long sources (§7.4)")
struct ChunkerTests {
    @Test("splits on paragraphs, keeps every word, respects the limit")
    func paragraphs() {
        let text = (1...10).map { "Paragraph \($0). " + String(repeating: "word ", count: 40) }.joined(separator: "\n\n")
        let chunks = Chunker.chunks(text, maxCharacters: 500)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: " ").split(separator: " ").filter { $0 == "word" }.count == 400)
        #expect(chunks[0].hasPrefix("Paragraph 1."))
    }

    @Test("a huge paragraph splits on sentences, and a huge sentence is cut")
    func longPieces() {
        let sentences = (1...30).map { "Sentence number \($0) is here." }.joined(separator: " ")
        #expect(Chunker.chunks(sentences, maxCharacters: 200).allSatisfy { $0.count <= 200 })
        let blob = String(repeating: "x", count: 1_050)
        let cut = Chunker.chunks(blob, maxCharacters: 400)
        #expect(cut.map(\.count) == [400, 400, 250])
        #expect(Chunker.chunks("short", maxCharacters: 500) == ["short"])
        #expect(Chunker.chunks("", maxCharacters: 500).isEmpty)
    }

    @Test("a long source becomes parts, each asked for its share, merged without repeats")
    func longSource() async throws {
        let client = FakeLLMClient(endpoint: .fake(contextWindowTokens: 2_000)) { request in
            let text = request.messages[0].text
            let part = text.contains("part 1 of") ? "1" : "n"
            return #"{"quiz":{"name":"Part \#(part)","cards":[{"prompt":"Shared question?","long_answer":"Same in every part.","short_answer":null,"hint":null},{"prompt":"Unique \#(UUID().uuidString)?","long_answer":"Only here.","short_answer":null,"hint":null}]}}"#
        }
        let source = (1...12).map { "Section \($0). " + String(repeating: "Content sentence here. ", count: 30) }.joined(separator: "\n\n")
        let parts = Mutex<[Int]>([])
        let quiz = try await QuizGenerator.generateFromSource(
            QuizGenRequest(source: .document, topic: "Doc", sourceContent: source, cardCount: 12),
            using: client,
            progress: { part, _ in parts.withLock { $0.append(part) } }
        )
        let requests = client.recorder.requests
        #expect(requests.count > 1, "split into parts")
        #expect(parts.withLock { $0 } == Array(1...requests.count))
        #expect(requests[0].messages[0].text.contains("This is part 1 of \(requests.count)"))
        #expect(requests[0].messages[0].text.contains("SOURCE-DOCUMENT"))
        #expect(quiz.name == "Part 1", "the first part names the quiz")
        #expect(quiz.cards.filter { $0.prompt == "Shared question?" }.count == 1, "repeated prompts are merged")
        #expect(quiz.cards.count == requests.count + 1)
    }

    @Test("a source that fits is one request")
    func shortSource() async throws {
        let client = FakeLLMClient.scripted([#"{"quiz":{"name":"One","cards":[{"prompt":"Q?","long_answer":"A.","short_answer":null,"hint":null}]}}"#])
        _ = try await QuizGenerator.generateFromSource(QuizGenRequest(source: .article, topic: "x", sourceContent: "Short article."), using: client)
        #expect(client.recorder.count == 1)
        #expect(!client.recorder.requests[0].messages[0].text.contains("This is part"))
    }
}

@Suite("Generation jobs (F-61)")
struct GenerationJobTests {
    @Test("jobs persist; a running job resumes as queued; finished jobs keep their state")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "jobs-\(UUID().uuidString)/jobs.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GenerationJobStore(url: url)
        var running = GenerationJob(title: "Running", source: .url(URL(string: "https://example.com/a")!))
        running.state = .running
        running.phase = .generating
        running.progress = 0.6
        var failed = GenerationJob(title: "Failed", source: .text("Some text"))
        failed.state = .failed("Server error")
        let topic = GenerationJob(title: "Topic", source: .topic(.init(topic: "Rome", cardCount: 10, difficulty: "intro", language: nil, tone: "formal", focus: nil, exclude: nil)))
        let file = GenerationJob(title: "notes.pdf", source: .file(name: "notes.pdf", bookmark: Data([1, 2]), kind: .pdf), regenerating: UUID())
        try store.save([running, failed, topic, file])

        let loaded = store.load()
        #expect(loaded.map(\.title) == ["Running", "Failed", "Topic", "notes.pdf"])
        #expect(loaded[0].state == .queued, "a job interrupted by a quit starts again")
        #expect(loaded[0].phase == .waiting)
        #expect(loaded[0].progress == 0)
        #expect(loaded[1].state == .failed("Server error"))
        #expect(loaded[2].source == topic.source)
        #expect(loaded[3].regenerating == file.regenerating)
        #expect(GenerationJobStore(url: url.appending(path: "missing.json")).load().isEmpty)
    }

    @Test("batch list keeps http(s) URLs once, in order, and reports the rest")
    func batchList() {
        let (urls, rejected) = BatchList.parse("""
        https://en.wikipedia.org/wiki/Tiberius
          http://example.com/a

        not a url
        ftp://files.example.com/x
        https://en.wikipedia.org/wiki/Tiberius
        """)
        #expect(urls.map(\.absoluteString) == ["https://en.wikipedia.org/wiki/Tiberius", "http://example.com/a"])
        #expect(rejected == ["not a url", "ftp://files.example.com/x"])
    }
}
