import AVFoundation
import AIQuizCore
import Foundation

@MainActor
@Observable
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    private let audio: AudioSessionCoordinator
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?

    /// Identifier of the voice that AVSpeech most recently actually used. Lets the UI
    /// detect silent fallbacks (e.g. user picked a Premium voice that isn't downloaded
    /// so iOS played a default voice instead).
    private(set) var lastUsedVoiceIdentifier: String?

    init(audio: AudioSessionCoordinator) {
        self.audio = audio
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                cont.resume()
                return
            }

            // 1. Cancel any in-flight utterance and resolve its continuation so we
            //    never orphan a previous `speak` call.
            cancelInFlight()

            // 2. Ask for playback (F-50). Inside a play-and-record session (voice hints, oral
            //    exam) the coordinator keeps that session instead.
            do {
                try audio.beginPlayback()
            } catch {
                // Non-fatal: speech usually still plays without explicit session setup.
                Log.audio.debug("TTS: playback session failed: \(error.localizedDescription)")
            }

            // 3. Build the utterance.
            let utterance = AVSpeechUtterance(string: trimmed)
            let settings = AppSettings.shared
            utterance.rate = settings.ttsRate
            utterance.voice = resolveVoice(preferredIdentifier: settings.ttsVoiceIdentifier)

            self.continuation = cont
            self.currentUtterance = utterance
            self.synthesizer.speak(utterance)
        }
    }

    private func resolveVoice(preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        if let id = preferredIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        if let best = VoiceCatalog.bestVoiceForCurrentLocale(),
           let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    /// Stops any in-flight speech and resolves the pending `speak(_:)` call.
    func stop() {
        cancelInFlight()
    }

    private func cancelInFlight() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let cont = continuation {
            continuation = nil
            currentUtterance = nil
            cont.resume()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let voiceID = utterance.voice?.identifier
        Task { @MainActor in self.lastUsedVoiceIdentifier = voiceID }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceId = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishUtterance(with: utteranceId) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceId = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishUtterance(with: utteranceId) }
    }

    private func finishUtterance(with id: ObjectIdentifier) {
        guard let current = currentUtterance, ObjectIdentifier(current) == id else { return }
        let cont = continuation
        continuation = nil
        currentUtterance = nil
        cont?.resume()
    }
}

/// Apple text to speech behind the `SpeechSynthesizing` protocol (SPEC F-51).
extension TTSService: SpeechSynthesizing {}
