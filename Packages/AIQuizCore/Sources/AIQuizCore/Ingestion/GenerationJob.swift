import Foundation

/// One quiz to generate, persisted so the queue survives relaunch (SPEC F-61).
public struct GenerationJob: Codable, Identifiable, Sendable, Equatable {
    public enum FileKind: String, Codable, Sendable { case markdown, pdf }

    public struct TopicOptions: Codable, Sendable, Equatable {
        public var topic: String
        public var cardCount: Int
        public var difficulty: String
        public var language: String?
        public var tone: String
        public var focus: String?
        public var exclude: String?
        /// Card kinds beyond recall (Phase 6); absent in jobs from older builds.
        public var kinds: [CardKind]?

        public init(topic: String, cardCount: Int, difficulty: String, language: String?, tone: String, focus: String?, exclude: String?, kinds: [CardKind]? = nil) {
            self.topic = topic
            self.cardCount = cardCount
            self.difficulty = difficulty
            self.language = language
            self.tone = tone
            self.focus = focus
            self.exclude = exclude
            self.kinds = kinds
        }
    }

    /// What the quiz is made from. Files are referenced by bookmark; photos and shared
    /// images are copied into the job's folder.
    public enum Source: Codable, Sendable, Equatable {
        case topic(TopicOptions)
        case url(URL)
        case text(String)
        case file(name: String, bookmark: Data, kind: FileKind)
        case images([String])
    }

    public enum Phase: String, Codable, Sendable {
        case waiting, fetching, extracting, generating, saving

        public var label: String {
            switch self {
            case .waiting: return "Waiting"
            case .fetching: return "Fetching"
            case .extracting: return "Reading"
            case .generating: return "Writing cards"
            case .saving: return "Saving"
            }
        }
    }

    public enum State: Codable, Sendable, Equatable {
        case queued
        case running
        case done(quizId: UUID)
        case failed(String)
        case cancelled
    }

    public var id: UUID
    public var title: String
    public var source: Source
    public var state: State
    public var phase: Phase
    /// 0…1 within the job.
    public var progress: Double
    public var createdAt: Date
    /// Set for *Regenerate from source* (F-4): the quiz being regenerated.
    public var regenerating: UUID?

    public init(id: UUID = UUID(), title: String, source: Source, createdAt: Date = .now, regenerating: UUID? = nil) {
        self.id = id
        self.title = title
        self.source = source
        self.state = .queued
        self.phase = .waiting
        self.progress = 0
        self.createdAt = createdAt
        self.regenerating = regenerating
    }

    public var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }

    /// Jobs a relaunch should pick up again: a job that was running when the app quit restarts.
    public func resumed() -> GenerationJob {
        guard state == .running else { return self }
        var job = self
        job.state = .queued
        job.phase = .waiting
        job.progress = 0
        return job
    }
}

/// The queue's JSON file in Application Support (SPEC F-61).
public struct GenerationJobStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [GenerationJob] {
        guard let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder().decode([GenerationJob].self, from: data) else { return [] }
        return jobs.map { $0.resumed() }
    }

    public func save(_ jobs: [GenerationJob]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(jobs).write(to: url, options: .atomic)
    }
}

/// One URL per line, as typed in *Batch from list* (F-61). Lines that aren't http(s)
/// addresses are returned separately so the screen can point at them.
public enum BatchList {
    public static func parse(_ text: String) -> (urls: [URL], rejected: [String]) {
        var urls: [URL] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
                if seen.insert(url.absoluteString).inserted { urls.append(url) }
            } else {
                rejected.append(trimmed)
            }
        }
        return (urls, rejected)
    }
}
