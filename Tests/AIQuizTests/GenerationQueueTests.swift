import XCTest
import Synchronization
import SwiftData
import AIQuizCore
import LLMKit
@testable import AIQuiz

/// SPEC F-61 generation queue, the Phase 5 pipeline and the share inbox (F-22).
@MainActor
final class GenerationQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var dir: URL!

    override func setUp() async throws {
        container = try StoreLoader.makeContainer(storeURL: nil, defaults: .standard).container
        dir = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    nonisolated private static func quizJSON(_ name: String) -> String {
        #"{"quiz":{"name":"\#(name)","cards":[{"prompt":"Q1?","long_answer":"A1.","short_answer":null,"hint":null},{"prompt":"Q2?","long_answer":"A2.","short_answer":null,"hint":null}]}}"#
    }

    /// A queue over a real pipeline with fake extraction and a fake model.
    private func makeQueue(client: FakeLLMClient, storeName: String = "jobs.json") -> GenerationQueue {
        let folders = dir.appending(path: "Jobs")
        let pipeline = GenerationPipeline(extractor: FakeSourceExtractor(), client: { client }, jobFolder: { folders.appending(path: $0.uuidString) })
        let context = self.context
        return GenerationQueue(
            store: GenerationJobStore(url: dir.appending(path: storeName)),
            foldersRoot: folders,
            pipeline: { job, report in try await pipeline.run(job, report: report) },
            save: { output, job in try GenerationQueue.saveQuiz(output, job: job, in: context) }
        )
    }

    private func quizzes() throws -> [QuizRecord] {
        try context.fetch(FetchDescriptor<QuizRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func testTenJobsCompleteInOrderEachMakingOneQuizWithCounters() async throws {
        let order = OrderRecorder()
        let client = FakeLLMClient { request in
            let text = request.messages[0].text
            let name = text.components(separatedBy: "Topic: ").dropFirst().first?.components(separatedBy: "\n").first ?? "?"
            order.append(name)
            return Self.quizJSON(name)
        }
        let queue = makeQueue(client: client)
        for i in 0..<10 {
            queue.enqueue(GenerationJob(title: "T\(i)", source: .topic(.init(topic: "T\(i)", cardCount: 5, difficulty: "intro", language: nil, tone: "formal", focus: nil, exclude: nil))))
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(order.values, (0..<10).map { "T\($0)" }, "serial, in order")
        let made = try quizzes()
        XCTAssertEqual(made.count, 10)
        XCTAssertTrue(made.allSatisfy { $0.cardCount == 2 && $0.dueCount == 2 && $0.origin == .topic })
        XCTAssertTrue(queue.jobs.isEmpty, "finished jobs leave the queue")
        XCTAssertEqual(GenerationJobStore(url: dir.appending(path: "jobs.json")).load(), [])
    }

    func testAWebPageJobKeepsTheArticleAndReportsItsPhases() async throws {
        let client = FakeLLMClient { _ in Self.quizJSON("Web quiz") }
        let pipeline = GenerationPipeline(extractor: FakeSourceExtractor(), client: { client }, jobFolder: { _ in self.dir })
        var phases: [GenerationJob.Phase] = []
        let output = try await pipeline.run(GenerationJob(title: "x", source: .url(URL(string: "https://example.com/a")!))) { phase, _ in
            if phases.last != phase { phases.append(phase) }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(phases.first, .fetching)
        XCTAssertTrue(phases.contains(.generating))
        XCTAssertEqual(phases.last, .saving)
        XCTAssertEqual(output.origin, .url)
        XCTAssertEqual(output.original?.kind, .webPage)
        XCTAssertEqual(output.original?.url?.host, "example.com")
        XCTAssertTrue(output.original?.text?.contains("Fixture article") == true)
        XCTAssertTrue(client.recorder.requests[0].messages[0].text.contains("SOURCE-ARTICLE"))
    }

    func testPendingJobsPersistAndResumeAfterARelaunch() async throws {
        let gate = Gate()
        let slow = FakeLLMClient { _ in
            await gate.wait()
            return Self.quizJSON("Slow")
        }
        let first = makeQueue(client: slow)
        first.enqueue(GenerationJob(title: "A", source: .text("Alpha text")))
        first.enqueue(GenerationJob(title: "B", source: .text("Beta text")))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.jobs.map(\.state), [.running, .queued])
        let saved = GenerationJobStore(url: dir.appending(path: "jobs.json")).load()
        XCTAssertEqual(saved.map(\.title), ["A", "B"], "pending jobs are on disk")
        XCTAssertEqual(saved.map(\.state), [.queued, .queued], "the running one comes back queued")

        // "Relaunch": a new queue over the same file with a working model.
        let fast = FakeLLMClient { _ in Self.quizJSON("Resumed") }
        let second = makeQueue(client: fast)
        XCTAssertEqual(second.jobs.count, 2)
        second.start()
        await second.waitUntilIdle()
        XCTAssertEqual(try quizzes().map(\.name), ["Resumed", "Resumed"])
        await gate.open()
    }

    func testCancellingARunningJobSavesNothingAndRetryRunsItAgain() async throws {
        let gate = Gate()
        let calls = OrderRecorder()
        let client = FakeLLMClient { _ in
            calls.append("call")
            if calls.values.count == 1 { await gate.wait() }
            return Self.quizJSON("After retry")
        }
        let queue = makeQueue(client: client)
        let job = GenerationJob(title: "Cancel me", source: .text("Some text"))
        queue.enqueue(job)
        try await Task.sleep(for: .milliseconds(100))
        queue.cancel(job.id)
        await gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(queue.jobs.first?.state, .cancelled)
        XCTAssertEqual(try quizzes().count, 0, "a cancelled job leaves no quiz")

        queue.retry(job.id)
        await queue.waitUntilIdle()
        XCTAssertEqual(try quizzes().map(\.name), ["After retry"])
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testAFailedJobShowsAFriendlyMessageAndCanBeRemoved() async throws {
        let client = FakeLLMClient { _ in throw LLMError.server(status: 503) }
        let queue = makeQueue(client: client)
        let job = GenerationJob(title: "Fails", source: .text("Text"))
        queue.enqueue(job)
        await queue.waitUntilIdle()
        guard case .failed(let message)? = queue.jobs.first?.state else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.contains("503 {"), "no response bodies: \(message)")
        queue.remove(job.id)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testShareInboxBecomesJobs() throws {
        let inbox = dir.appending(path: "Inbox")
        let kept = dir.appending(path: "Kept")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        func item(_ id: String, _ json: String) throws { try Data(json.utf8).write(to: inbox.appending(path: "\(id).json")) }
        try item("1", #"{"kind":"url","value":"https://en.wikipedia.org/wiki/Rome"}"#)
        try item("2", #"{"kind":"text","value":"Shared paragraph about Rome.","name":"Shared paragraph"}"#)
        try Data("%PDF-1.4 fake".utf8).write(to: inbox.appending(path: "3.pdf"))
        try item("3", #"{"kind":"pdf","file":"3.pdf","name":"notes.pdf"}"#)
        try Data([0xFF, 0xD8, 0xFF]).write(to: inbox.appending(path: "4.jpg"))
        try item("4", #"{"kind":"image","file":"4.jpg","name":"Shared image"}"#)
        try item("5", "not json")

        let gate = Gate()
        let queue = makeQueue(client: FakeLLMClient { _ in await gate.wait(); return Self.quizJSON("x") })
        ShareInbox.drain(from: inbox, keepFilesIn: kept, into: queue)

        XCTAssertEqual(queue.jobs.count, 4)
        XCTAssertEqual(queue.jobs[0].source, .url(URL(string: "https://en.wikipedia.org/wiki/Rome")!))
        XCTAssertEqual(queue.jobs[1].source, .text("Shared paragraph about Rome."))
        guard case .file(let name, _, let kind) = queue.jobs[2].source else { return XCTFail("expected a file job") }
        XCTAssertEqual(name, "notes.pdf")
        XCTAssertEqual(kind, .pdf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path).count, 1, "the PDF is kept for its link")
        guard case .images(let names) = queue.jobs[3].source else { return XCTFail("expected an image job") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.folder(for: queue.jobs[3].id).appending(path: names[0]).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "the inbox is emptied")
        Task { await gate.open() }
    }
}

/// Thread-safe list for recording calls from fake handlers.
private final class OrderRecorder: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ value: String) { storage.withLock { $0.append(value) } }
    var values: [String] { storage.withLock { $0 } }
}

/// Holds fake model calls until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
