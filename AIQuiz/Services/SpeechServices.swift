import Foundation
import AIQuizCore

/// The speech implementations the players use (SPEC F-51), chosen once at the composition
/// root: Apple's in the app, scripted ones in UI-test mode so voice flows run on the simulator.
@MainActor
@Observable
final class SpeechServices {
    let synthesizer: any SpeechSynthesizing
    let recognizer: any SpeechRecognizing
    /// Listens for the spoken "hint" command (F-12): the same recognizer in the app, one that
    /// hears "hint" in UI-test mode.
    let hintListener: any SpeechRecognizing
    /// The audio session's one owner (F-50); sessions that speak and listen hold it in
    /// play-and-record.
    let audio: AudioSessionCoordinator

    init(synthesizer: any SpeechSynthesizing, recognizer: any SpeechRecognizing, hintListener: (any SpeechRecognizing)? = nil, audio: AudioSessionCoordinator) {
        self.synthesizer = synthesizer
        self.recognizer = recognizer
        self.hintListener = hintListener ?? recognizer
        self.audio = audio
    }

    static func make(for environment: AppEnvironment) -> SpeechServices {
        if environment.isUITest {
            return SpeechServices(
                synthesizer: ScriptedSynthesizer(mode: .immediate(delay: .milliseconds(250))),
                recognizer: ScriptedRecognizer(),
                hintListener: ScriptedRecognizer(partial: "hint", final: "hint please"),
                audio: AudioSessionCoordinator(backend: RecordingAudioBackend())
            )
        }
        let audio = AudioSessionCoordinator.makeSystem()
        return SpeechServices(synthesizer: TTSService(audio: audio), recognizer: STTService(audio: audio), audio: audio)
    }
}
