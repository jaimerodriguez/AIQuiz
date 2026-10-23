import Foundation
import AIQuizCore

/// The speech implementations the players use (SPEC F-51), chosen once at the composition
/// root: Apple's in the app, scripted ones in UI-test mode so voice flows run on the simulator.
@MainActor
@Observable
final class SpeechServices {
    let synthesizer: any SpeechSynthesizing
    let recognizer: any SpeechRecognizing

    init(synthesizer: any SpeechSynthesizing, recognizer: any SpeechRecognizing) {
        self.synthesizer = synthesizer
        self.recognizer = recognizer
    }

    static func make(for environment: AppEnvironment) -> SpeechServices {
        if environment.isUITest {
            return SpeechServices(
                synthesizer: ScriptedSynthesizer(mode: .immediate(delay: .milliseconds(250))),
                recognizer: ScriptedRecognizer()
            )
        }
        return SpeechServices(synthesizer: TTSService.shared, recognizer: STTService.shared)
    }
}
