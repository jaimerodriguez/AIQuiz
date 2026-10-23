import Foundation

/// What the app's audio session is set up for (SPEC F-50).
public enum AudioSessionMode: String, Sendable, Equatable {
    case inactive
    /// Speech output only (`.playback`, spoken audio).
    case playback
    /// Microphone only (`.record`), as Quiz — Voice uses between prompts.
    case recording
    /// Speaking and listening in one session: voice hints and the oral exam, which switch
    /// between the two every few seconds.
    case playAndRecord
}

/// Applies a mode to the real audio session. The app's implementation wraps `AVAudioSession`;
/// tests use `RecordingAudioBackend`.
@MainActor
public protocol AudioSessionBackend: AnyObject {
    func apply(_ mode: AudioSessionMode) throws
}

/// The one owner of the audio session (SPEC F-50). Text to speech and speech recognition ask
/// it for what they need and never touch the session themselves.
///
/// Every call is idempotent: asking for the mode already in force does nothing. While a
/// session holds `playAndRecord`, requests for playback or recording are already satisfied
/// and leave it alone (or set it up again after a system reset); only `end()` releases it.
@MainActor
public final class AudioSessionCoordinator {
    public private(set) var mode: AudioSessionMode = .inactive
    /// A session asked for `playAndRecord` and has not ended; survives a system reset.
    public private(set) var holdsPlayAndRecord = false
    private let backend: AudioSessionBackend
    private let log: (String) -> Void

    public init(backend: AudioSessionBackend, log: @escaping (String) -> Void = { _ in }) {
        self.backend = backend
        self.log = log
    }

    public func beginPlayback() throws {
        try transition(to: holdsPlayAndRecord ? .playAndRecord : .playback)
    }

    public func beginRecording() throws {
        try transition(to: holdsPlayAndRecord ? .playAndRecord : .recording)
    }

    public func beginPlayAndRecord() throws {
        try transition(to: .playAndRecord)
        holdsPlayAndRecord = true
    }

    /// Recognition stopped: release a record-only session so other apps' audio resumes.
    /// A `playAndRecord` session stays up until its owner calls `end()`.
    public func endRecording() {
        guard mode == .recording else { return }
        end()
    }

    /// Deactivates the session and lets other apps' audio resume.
    public func end() {
        holdsPlayAndRecord = false
        do {
            try transition(to: .inactive)
        } catch {
            // Deactivating fails while audio is still running; forget the mode anyway so the
            // next request sets the session up again.
            log("audio: end failed (\(error.localizedDescription)); marked inactive")
            mode = .inactive
        }
    }

    /// The system took the session away (an interruption or a media services reset): the next
    /// request sets it up again instead of trusting the mode on record.
    public func sessionWasReset() {
        guard mode != .inactive else { return }
        log("audio: \(mode.rawValue) → inactive (reset by the system)")
        mode = .inactive
    }

    private func transition(to newMode: AudioSessionMode) throws {
        guard newMode != mode else { return }
        do {
            try backend.apply(newMode)
        } catch {
            log("audio: \(mode.rawValue) → \(newMode.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
        log("audio: \(mode.rawValue) → \(newMode.rawValue)")
        mode = newMode
    }
}

/// A backend that records what it was asked to apply, for tests and UI-test mode.
@MainActor
public final class RecordingAudioBackend: AudioSessionBackend {
    public private(set) var applied: [AudioSessionMode] = []
    /// Modes whose `apply` throws.
    public var failing: Set<AudioSessionMode> = []

    public struct Failure: LocalizedError {
        public var errorDescription: String? { "The audio session could not be set up." }
    }

    public init() {}

    public func apply(_ mode: AudioSessionMode) throws {
        if failing.contains(mode) { throw Failure() }
        applied.append(mode)
    }
}
