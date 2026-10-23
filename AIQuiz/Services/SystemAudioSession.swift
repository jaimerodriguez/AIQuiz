import AVFoundation
import AIQuizCore

/// `AVAudioSession` behind the coordinator (SPEC F-50). The only code in the app that sets
/// the session's category or activates it.
///
/// The configurations are the ones that proved stable on the iPad (`known_issues.md` §1):
/// no `.measurement` mode and no preferred input.
@MainActor
final class SystemAudioSession: AudioSessionBackend {
    private var observers: [NSObjectProtocol] = []

    /// `onReset` runs when the system takes the session away (an interruption begins or media
    /// services reset), so the coordinator sets it up again on the next request.
    init(onReset: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        let reset: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in onReset() }
        }
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil, using: reset),
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil, using: reset)
        ]
    }

    func apply(_ mode: AudioSessionMode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        case .recording:
            try session.setCategory(.record)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        case .playAndRecord:
            // Speaker rather than the receiver on iPhone; AirPods keep high-quality output.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        case .inactive:
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

extension AudioSessionCoordinator {
    /// The app's coordinator: the real session, transitions logged to the debug log (F-50).
    static func makeSystem() -> AudioSessionCoordinator {
        weak var coordinator: AudioSessionCoordinator?
        let backend = SystemAudioSession(onReset: { coordinator?.sessionWasReset() })
        let made = AudioSessionCoordinator(backend: backend, log: { Log.audio.debug($0) })
        coordinator = made
        return made
    }
}
