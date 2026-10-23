import Foundation
import AIQuizCore
import LLMKit
import Observation

/// What one job produced, ready to save as a quiz.
struct GenerationOutput {
    var payload: QuizPayload
    var origin: QuizOrigin
    var original: OriginalSource?
    var endpoint: LLMEndpoint
}

/// Runs one job: fetch or read the source, then write the cards (SPEC §6, §7.4).
@MainActor
struct GenerationPipeline {
    let extractor: SourceExtracting
    let client: () throws -> LLMClient
    let jobFolder: (UUID) -> URL

    func run(_ job: GenerationJob, report: @escaping @MainActor (GenerationJob.Phase, Double) -> Void) async throws -> GenerationOutput {
        let client = try client()
        let reportExtracting: @Sendable (Double) -> Void = { fraction in Task { @MainActor in report(.extracting, fraction) } }
        let reportParts: @Sendable (Int, Int) -> Void = { part, of in Task { @MainActor in report(.generating, Double(part - 1) / Double(max(1, of))) } }

        let request: QuizGenRequest
        let origin: QuizOrigin
        let original: OriginalSource?
        switch job.source {
        case .topic(let options):
            report(.generating, 0)
            request = QuizGenRequest(source: .topic, topic: options.topic, cardCount: options.cardCount, difficulty: options.difficulty,
                                     language: options.language, tone: options.tone, focus: options.focus, exclude: options.exclude)
            origin = .topic
            original = nil
        case .url(let url):
            report(.fetching, 0)
            let article = try await extractor.article(from: url)
            request = QuizGenRequest(source: .article, topic: article.title ?? url.host ?? "Quiz", sourceContent: article.text)
            origin = .url
            original = OriginalSource(kind: .webPage, title: url.host ?? "Web page", text: article.text, url: url)
        case .text(let text):
            request = QuizGenRequest(source: .markdown, topic: "Quiz", sourceContent: text)
            origin = .pastedText
            original = OriginalSource(kind: .pastedText, title: "Pasted text", text: text)
        case .file(let name, let bookmark, let kind):
            report(.extracting, 0)
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw SourceExtractionError.notReadable(name)
            }
            switch kind {
            case .markdown:
                let text = try await ContentExtractor.loadMarkdown(url)
                request = QuizGenRequest(source: .markdown, topic: (name as NSString).deletingPathExtension, sourceContent: text)
                origin = .markdown
                original = OriginalSource(kind: .markdownFile, title: name, text: text, fileBookmark: bookmark)
            case .pdf:
                let text = try await extractor.pdfText(at: url, progress: reportExtracting)
                request = QuizGenRequest(source: .document, topic: (name as NSString).deletingPathExtension, sourceContent: text)
                origin = .pdf
                original = OriginalSource(kind: .pdfFile, title: name, text: text, fileBookmark: bookmark)
            }
        case .images(let names):
            report(.extracting, 0)
            let folder = jobFolder(job.id)
            let text = try await extractor.imageText(names.map { folder.appending(path: $0) }, progress: reportExtracting)
            request = QuizGenRequest(source: .document, topic: "Scanned pages", sourceContent: text)
            origin = .image
            original = OriginalSource(kind: .scannedPages, title: "\(names.count) scanned page\(names.count == 1 ? "" : "s")", text: text)
        }

        try Task.checkCancellation()
        report(.generating, 0)
        let payload = try await QuizGenerator.generateFromSource(request, using: client, progress: reportParts)
        try Task.checkCancellation()
        report(.saving, 1)
        return GenerationOutput(payload: payload, origin: origin, original: original, endpoint: client.endpoint)
    }
}

/// The persistent, serial generation queue (SPEC F-61). Generate, *Batch from list*, the
/// share inbox and *Regenerate* all enqueue here; the library shows the jobs.
@MainActor
@Observable
final class GenerationQueue {
    private(set) var jobs: [GenerationJob]
    /// Called with the quiz name when a job finishes, for the background notification.
    var onFinished: ((String) -> Void)?

    private let store: GenerationJobStore
    private let foldersRoot: URL
    private let pipeline: (GenerationJob, @escaping @MainActor (GenerationJob.Phase, Double) -> Void) async throws -> GenerationOutput
    private let save: (GenerationOutput, GenerationJob) throws -> UUID
    private var runner: Task<Void, Never>?
    private var current: UUID?
    private var currentTask: Task<GenerationOutput, Error>?
    /// Jobs the user cancelled while running: whatever the pipeline then throws or returns,
    /// they end as cancelled and save nothing.
    private var cancelRequested: Set<UUID> = []

    init(
        store: GenerationJobStore,
        foldersRoot: URL,
        pipeline: @escaping (GenerationJob, @escaping @MainActor (GenerationJob.Phase, Double) -> Void) async throws -> GenerationOutput,
        save: @escaping (GenerationOutput, GenerationJob) throws -> UUID
    ) {
        self.store = store
        self.foldersRoot = foldersRoot
        self.pipeline = pipeline
        self.save = save
        self.jobs = store.load().filter { !$0.isDone }
    }

    /// Jobs not yet finished or still worth showing (failed or cancelled until removed).
    var visibleJobs: [GenerationJob] { jobs }
    var pendingCount: Int { jobs.filter { $0.state == .queued || $0.state == .running }.count }

    func folder(for id: UUID) -> URL {
        foldersRoot.appending(path: id.uuidString)
    }

    func enqueue(_ job: GenerationJob) {
        jobs.append(job)
        persist()
        start()
    }

    /// Starts the runner if it is idle. Safe to call any time (launch, foreground, enqueue).
    func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let next = self.jobs.first(where: { $0.state == .queued }) {
                await self.run(next.id)
            }
            self?.runner = nil
        }
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if current == id {
            cancelRequested.insert(id)
            currentTask?.cancel()
        } else if jobs[index].state == .queued {
            jobs[index].state = .cancelled
            persist()
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .failed, .cancelled:
            jobs[index].state = .queued
            jobs[index].phase = .waiting
            jobs[index].progress = 0
            persist()
            start()
        default:
            break
        }
    }

    func remove(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .running else { return }
        jobs.remove(at: index)
        try? FileManager.default.removeItem(at: folder(for: id))
        persist()
    }

    /// Waits until no job is queued or running (tests).
    func waitUntilIdle() async {
        while let runner { await runner.value }
    }

    private func run(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .running
        jobs[index].phase = .waiting
        current = id
        persist()
        let job = jobs[index]
        let report: @MainActor (GenerationJob.Phase, Double) -> Void = { [weak self] phase, fraction in
            self?.update(id) { $0.phase = phase; $0.progress = fraction }
        }
        let task = Task { @MainActor [pipeline] in
            try await pipeline(job, report)
        }
        currentTask = task
        do {
            let output = try await task.value
            if cancelRequested.contains(id) { throw CancellationError() }
            let quizId = try save(output, job)
            jobs.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: folder(for: id))
            Log.ai.info("Generated a quiz in the background (\(output.payload.cards.count) cards)")
            onFinished?(output.payload.name)
            _ = quizId
        } catch where cancelRequested.contains(id) || error is CancellationError || (error as? LLMError) == .cancelled {
            update(id) { $0.state = .cancelled }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(id) { $0.state = .failed(message) }
        }
        cancelRequested.remove(id)
        current = nil
        currentTask = nil
        persist()
    }

    private func update(_ id: UUID, _ change: (inout GenerationJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func persist() {
        do {
            try store.save(jobs)
        } catch {
            Log.data.error("Saving the generation queue failed: \(String(describing: error))")
        }
    }
}

private extension GenerationJob {
    var isDone: Bool {
        if case .done = state { return true }
        return false
    }
}
