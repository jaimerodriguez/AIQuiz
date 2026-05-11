import AVFoundation
import Foundation
import Speech

enum STTAuthorisation {
    case authorized
    case denied
    case notDetermined
}

enum STTError: LocalizedError {
    case unauthorized
    case unavailable
    case audioSession(Error)
    case engineStart(Error)
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Speech recognition isn't authorised."
        case .unavailable: return "Speech recognition is unavailable on this device."
        case .audioSession(let e): return "Audio session failure: \(e.localizedDescription)"
        case .engineStart(let e): return "Couldn't start the audio engine: \(e.localizedDescription)"
        case .streamFailed(let e): return "Recognition stream failed: \(e.localizedDescription)"
        }
    }
}

/// Streaming speech recogniser. Each `startListening` call gets a FRESH
/// `AVAudioEngine` instance — keeping a long-lived singleton engine across
/// sessions causes the audio HAL to crash on some iPads (no .ips report,
/// watchdog kill ~20 ms after the post-`setActive` `categoryChange` route
/// notification fires).
@MainActor
@Observable
final class STTService {
    static let shared = STTService()

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var requestRef: RequestRef?
    private var task: SFSpeechRecognitionTask?
    private var tappedInput: AVAudioInputNode?

    /// Sendable wrapper for the recognition request. The audio tap closure runs
    /// off the main actor, so it must not capture any @MainActor-isolated value
    /// directly. Capturing this box lets the closure null out the reference on
    /// teardown without touching main-actor state.
    private final class RequestRef: @unchecked Sendable {
        var value: SFSpeechAudioBufferRecognitionRequest?
        init(_ v: SFSpeechAudioBufferRecognitionRequest) { self.value = v }
    }

    /// Same idea for the recognition task callback, which is also invoked off
    /// the main actor.
    private final class WeakSelfBox: @unchecked Sendable {
        weak var value: STTService?
        init(_ v: STTService) { self.value = v }
    }

    private(set) var liveTranscript: String = ""
    private var transcriptHandler: ((String) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private(set) var isListening: Bool = false

    func authorisationStatus() -> STTAuthorisation {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAuthorisation() async -> STTAuthorisation {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized: cont.resume(returning: .authorized)
                case .notDetermined: cont.resume(returning: .notDetermined)
                default: cont.resume(returning: .denied)
                }
            }
        }
    }

    func startListening(
        locale: Locale = .current,
        onTranscript: ((String) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) throws {
        DebugLog.log("STT.startListening: entering")
        teardown()

        guard authorisationStatus() == .authorized else { throw STTError.unauthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw STTError.unavailable
        }

        // Audio session: minimal record-only config. No mode, no options. The
        // simpler this is the better — extra options were what destabilised
        // the engine in earlier attempts.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            DebugLog.log("STT: session active route=\(session.currentRoute.inputs.first?.portName ?? "none")")
        } catch {
            throw STTError.audioSession(error)
        }

        // Fresh engine per session — never reuse.
        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        self.tappedInput = inputNode

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        // The tap closure runs on AVAudioNodeTap::RealtimeMessenger's dispatch
        // queue. Because STTService is @MainActor-isolated, ANY closure created
        // inside this method inherits @MainActor isolation — and Swift 6 injects
        // `swift_task_checkIsolatedSwift` at closure entry, which SIGTRAPs the
        // moment a buffer arrives off the main actor.
        //
        // The fix: declare the closure with an explicit `@Sendable` function
        // type, which severs the inherited isolation. Captures must be Sendable;
        // we pass the request via `RequestRef` (`@unchecked Sendable`).
        let requestRef = RequestRef(request)
        self.requestRef = requestRef
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            requestRef.value?.append(buffer)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)
        DebugLog.log("STT: tap installed (format=nil)")

        self.transcriptHandler = onTranscript
        self.errorHandler = onError
        self.liveTranscript = ""

        // Same isolation trap applies to the recognition callback — declare it
        // as a @Sendable function-typed closure to break inherited @MainActor.
        let selfBox = WeakSelfBox(self)
        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor in
                    guard let me = selfBox.value else { return }
                    me.liveTranscript = text
                    me.transcriptHandler?(text)
                    if isFinal { me.teardown() }
                }
            }
            if let error {
                Task { @MainActor in
                    guard let me = selfBox.value else { return }
                    me.errorHandler?(error)
                    me.teardown()
                }
            }
        }
        self.task = recognizer.recognitionTask(with: request, resultHandler: resultHandler)

        engine.prepare()
        do {
            try engine.start()
            DebugLog.log("STT: engine started")
            isListening = true
        } catch {
            DebugLog.log("STT: engine.start failed: \(error)")
            teardown()
            throw STTError.engineStart(error)
        }
    }

    func stopListening() {
        teardown()
    }

    private func teardown() {
        if let engine, engine.isRunning {
            engine.stop()
        }
        if let input = tappedInput {
            input.removeTap(onBus: 0)
        }
        tappedInput = nil
        request?.endAudio()
        requestRef?.value = nil
        requestRef = nil
        task?.cancel()
        task = nil
        request = nil
        engine = nil
        transcriptHandler = nil
        errorHandler = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
