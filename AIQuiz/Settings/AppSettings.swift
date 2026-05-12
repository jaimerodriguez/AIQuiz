import AVFoundation
import Foundation
import Observation
import SwiftUI

enum StudyReadStyle: String, CaseIterable, Identifiable {
    case flipCard
    case allAtOnce

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flipCard: return "Flip card"
        case .allAtOnce: return "All at once"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private let kStudyReadStyle = "studyReadStyle"
    private let kStudyVoiceRepeat = "studyVoiceRepeatCount"
    private let kStudyVoicePause = "studyVoicePauseSeconds"
    private let kTTSVoiceIdentifier = "ttsVoiceIdentifier"
    private let kTTSRate = "ttsRate"
    private let kQuizFontSize = "quizFontSize"
    private let kAppearanceMode = "appearanceMode"

    var studyReadStyle: StudyReadStyle {
        didSet { defaults.set(studyReadStyle.rawValue, forKey: kStudyReadStyle) }
    }

    var studyVoiceRepeatCount: Int {
        didSet { defaults.set(studyVoiceRepeatCount, forKey: kStudyVoiceRepeat) }
    }

    var studyVoicePauseSeconds: Double {
        didSet { defaults.set(studyVoicePauseSeconds, forKey: kStudyVoicePause) }
    }

    /// `nil` means "let the app pick the best installed voice for the current locale."
    var ttsVoiceIdentifier: String? {
        didSet {
            if let id = ttsVoiceIdentifier {
                defaults.set(id, forKey: kTTSVoiceIdentifier)
            } else {
                defaults.removeObject(forKey: kTTSVoiceIdentifier)
            }
        }
    }

    var ttsRate: Float {
        didSet { defaults.set(ttsRate, forKey: kTTSRate) }
    }

    var quizFontSize: QuizFontSize {
        didSet { defaults.set(quizFontSize.rawValue, forKey: kQuizFontSize) }
    }

    var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: kAppearanceMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: kStudyReadStyle) ?? StudyReadStyle.flipCard.rawValue
        self.studyReadStyle = StudyReadStyle(rawValue: raw) ?? .flipCard
        let repeats = defaults.object(forKey: kStudyVoiceRepeat) as? Int ?? 1
        self.studyVoiceRepeatCount = max(1, min(5, repeats))
        let pause = defaults.object(forKey: kStudyVoicePause) as? Double ?? 1.0
        self.studyVoicePauseSeconds = max(0.5, min(3.0, pause))
        let savedVoice = defaults.string(forKey: kTTSVoiceIdentifier)
        // If the saved voice has been uninstalled or renamed, fall back to Auto so
        // we don't try to use an identifier that AVSpeech will silently ignore.
        if let id = savedVoice, AVSpeechSynthesisVoice(identifier: id) == nil {
            defaults.removeObject(forKey: kTTSVoiceIdentifier)
            self.ttsVoiceIdentifier = nil
        } else {
            self.ttsVoiceIdentifier = savedVoice
        }
        let storedRate = defaults.object(forKey: kTTSRate) as? Double
        self.ttsRate = Float(storedRate ?? 0.5)
        let fontRaw = defaults.object(forKey: kQuizFontSize) as? Int ?? QuizFontSize.large.rawValue
        self.quizFontSize = QuizFontSize(rawValue: fontRaw) ?? .large
        let appearanceRaw = defaults.string(forKey: kAppearanceMode) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: appearanceRaw) ?? .system
    }
}
