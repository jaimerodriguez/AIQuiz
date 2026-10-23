import Foundation

/// Whether the app may listen (SPEC F-51).
public enum SpeechAuthorisation: Sendable, Equatable {
    case authorized
    case microphoneDenied
    case speechDenied
}

/// Text to speech (SPEC F-51). Apple's `AVSpeechSynthesizer` is the default implementation;
/// players depend only on this protocol.
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    /// Speaks and returns when the utterance finishes or is stopped.
    func speak(_ text: String) async
    func pause()
    func resume()
    /// Stops speech and resolves any pending `speak`.
    func stop()
    /// The voice the system actually used last, to detect silent fallbacks.
    var lastUsedVoiceIdentifier: String? { get }
}

/// Live speech to text (SPEC F-51).
@MainActor
public protocol SpeechRecognizing: AnyObject {
    /// Asks for microphone and speech-recognition access when needed.
    func authorisation() async -> SpeechAuthorisation
    func start(
        locale: Locale,
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws
    func stop()
}

/// A synthesizer for tests and UI-test mode. In `.immediate` mode each utterance finishes
/// after `delay`; in `.manual` mode it waits for `finishCurrent()`.
@MainActor
public final class ScriptedSynthesizer: SpeechSynthesizing {
    public enum Mode: Sendable { case immediate(delay: Duration), manual }

    public private(set) var spoken: [String] = []
    public private(set) var pauseCount = 0
    public private(set) var resumeCount = 0
    public private(set) var stopCount = 0
    public var lastUsedVoiceIdentifier: String? { "scripted" }
    public var isSpeaking: Bool { pending != nil }

    private let mode: Mode
    private var pending: CheckedContinuation<Void, Never>?

    public init(mode: Mode = .immediate(delay: .zero)) {
        self.mode = mode
    }

    public func speak(_ text: String) async {
        finishCurrent()
        spoken.append(text)
        switch mode {
        case .immediate(let delay):
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
        case .manual:
            await withCheckedContinuation { pending = $0 }
        }
    }

    /// Finishes the utterance in progress (manual mode).
    public func finishCurrent() {
        let cont = pending
        pending = nil
        cont?.resume()
    }

    public func pause() { pauseCount += 1 }
    public func resume() { resumeCount += 1 }

    public func stop() {
        stopCount += 1
        finishCurrent()
    }
}

/// A recognizer for tests and UI-test mode: reports `partial`, then `final` after `delay`.
@MainActor
public final class ScriptedRecognizer: SpeechRecognizing {
    public var access: SpeechAuthorisation
    public var partial: String
    public var final: String
    public var delay: Duration
    public var startError: Error?
    public private(set) var startedLocales: [Locale] = []
    public private(set) var stopCount = 0
    private var task: Task<Void, Never>?

    public init(access: SpeechAuthorisation = .authorized, partial: String = "Fixture", final: String = "Fixture answer", delay: Duration = .milliseconds(300)) {
        self.access = access
        self.partial = partial
        self.final = final
        self.delay = delay
    }

    public func authorisation() async -> SpeechAuthorisation { access }

    public func start(
        locale: Locale,
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws {
        if let startError { throw startError }
        startedLocales.append(locale)
        let (partial, final, delay) = (self.partial, self.final, self.delay)
        task = Task { @MainActor in
            onPartial(partial)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onFinal(final)
        }
    }

    public func stop() {
        stopCount += 1
        task?.cancel()
        task = nil
    }
}
