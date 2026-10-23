import Foundation
import os

/// Unified logging, one category per area. Messages are marked public so they are
/// readable in Console and `log show`. Never pass transcripts, source text or API
/// keys (SPEC N-7). The opt-in file sink (S-14) arrives in PLAN Phase 3.
struct Log: Sendable {
    static let app = Log(category: "app")
    static let audio = Log(category: "audio")
    static let ai = Log(category: "ai")
    static let data = Log(category: "data")

    private let logger: Logger

    private init(category: String) {
        logger = Logger(subsystem: "com.jaimerodriguez.aiquiz", category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
