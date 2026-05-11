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
    case recordingFailed(String)
    case noRecording
    case transcriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Speech recognition isn't authorised."
        case .unavailable: return "Speech recognition is unavailable on this device."
        case .recordingFailed(let m): return "Couldn't record audio: \(m)"
        case .noRecording: return "No recording to transcribe."
        case .transcriptionFailed(let e):
            return "Transcription failed: \(e.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class STTService {
    static let shared = STTService()

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var levelTask: Task<Void, Never>?

    /// 0…1 normalised meter level (updated while recording).
    private(set) var level: Float = 0
    private(set) var isRecording: Bool = false

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

    func startRecording() throws {
        stopRecording()
        DebugLog.log("STT.startRecording: entering")

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            DebugLog.log("STT.recording: session active route=\(session.currentRoute.inputs.first?.portName ?? "none")")
        } catch {
            DebugLog.log("STT.recording: session error: \(error)")
            throw STTError.recordingFailed(error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquiz-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            DebugLog.log("STT.recording: AVAudioRecorder init failed: \(error)")
            throw STTError.recordingFailed(error.localizedDescription)
        }
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            DebugLog.log("STT.recording: prepareToRecord returned false")
            throw STTError.recordingFailed("prepareToRecord returned false")
        }
        guard recorder.record() else {
            DebugLog.log("STT.recording: record() returned false")
            throw STTError.recordingFailed("record() returned false")
        }
        DebugLog.log("STT.recording: started, url=\(url.lastPathComponent)")

        self.recorder = recorder
        self.recordingURL = url
        self.isRecording = true
        startLevelTimer()
    }

    func stopRecording() {
        levelTask?.cancel()
        levelTask = nil
        if let r = recorder, r.isRecording {
            r.stop()
            DebugLog.log("STT.recording: stopped, duration=\(String(format: "%.2f", r.currentTime))s")
        }
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Transcribes the most-recent recording via SFSpeechURLRecognitionRequest.
    func transcribeLastRecording(locale: Locale = .current) async throws -> String {
        guard let url = recordingURL else { throw STTError.noRecording }
        DebugLog.log("STT.transcribe: starting on \(url.lastPathComponent)")
        if authorisationStatus() != .authorized {
            let result = await requestAuthorisation()
            guard result == .authorized else { throw STTError.unauthorized }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw STTError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let text: String = try await withCheckedThrowingContinuation { cont in
            nonisolated(unsafe) var resolved = false
            recognizer.recognitionTask(with: request) { result, error in
                if resolved { return }
                if let error {
                    resolved = true
                    DebugLog.log("STT.transcribe: error \(error)")
                    cont.resume(throwing: STTError.transcriptionFailed(error))
                    return
                }
                if let result, result.isFinal {
                    resolved = true
                    let formatted = result.bestTranscription.formattedString
                    DebugLog.log("STT.transcribe: done (\(formatted.count) chars)")
                    cont.resume(returning: formatted)
                }
            }
        }

        // Best-effort cleanup of the temp file.
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil
        return text
    }

    private func startLevelTimer() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let recorder = self?.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let dB = recorder.averagePower(forChannel: 0)
                // Map -60dB..0dB to 0..1
                let normalised = max(0, (dB + 60) / 60)
                self?.level = Float(normalised)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }
}
