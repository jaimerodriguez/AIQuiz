import Foundation
import os
import Synchronization

/// Unified logging, one category per area. Messages are marked public so they are
/// readable in Console and `log show`. Never pass transcripts, source text or API
/// keys (SPEC N-7). With Debug logging on (S-14) messages are also appended to
/// `Log.file`, which stays on the device until the user shares or clears it.
struct Log: Sendable {
    static let app = Log(category: "app")
    static let audio = Log(category: "audio")
    static let ai = Log(category: "ai")
    static let data = Log(category: "data")

    /// The opt-in file sink. Off unless the user turns on Debug logging.
    static let file = DebugLogFile(url: URL.cachesDirectory.appending(path: "debug.log"))

    private let logger: Logger
    private let category: String

    private init(category: String) {
        self.category = category
        logger = Logger(subsystem: "com.jaimerodriguez.aiquiz", category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        Log.file.append(level: "debug", category: category, message)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        Log.file.append(level: "info", category: category, message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Log.file.append(level: "error", category: category, message)
    }
}

/// Appends log lines to a file while enabled (SPEC S-14). Keeps at most `maxBytes` by
/// dropping the older half when the file grows past it. Thread-safe.
final class DebugLogFile: Sendable {
    let url: URL
    let maxBytes: Int
    private let enabled = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "com.jaimerodriguez.aiquiz.debuglog")

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }

    func append(level: String, category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "\(Date.now.ISO8601Format()) [\(level)] [\(category)] \(message)\n"
        queue.async { [url, maxBytes] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            if let size = try? handle.offset(), size > UInt64(maxBytes),
               let data = try? Data(contentsOf: url) {
                try? data.suffix(maxBytes / 2).write(to: url, options: .atomic)
            }
        }
    }

    /// Waits for pending writes, for tests and before sharing.
    func flush() {
        queue.sync {}
    }

    var size: Int {
        flush()
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
