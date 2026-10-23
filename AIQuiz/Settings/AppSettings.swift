import AVFoundation
import AIQuizCore
import Foundation
import Observation
import SwiftUI

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

/// Library sort order (SPEC F-1).
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case name
    case mostDue
    case newest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recently studied"
        case .name: return "Name"
        case .mostDue: return "Most due"
        case .newest: return "Newest"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings(defaults: AppEnvironment.defaults)

    private let defaults: UserDefaults
    private let kStudyReadStyle = "studyReadStyle"
    private let kStudyVoiceRepeat = "studyVoiceRepeatCount"
    private let kStudyVoicePause = "studyVoicePauseSeconds"
    private let kTTSVoiceIdentifier = "ttsVoiceIdentifier"
    private let kTTSRate = "ttsRate"
    private let kQuizFontSize = "quizFontSize"
    private let kAppearanceMode = "appearanceMode"
    private let kLibrarySort = "librarySort"
    private let kSTTLocale = "sttLocaleIdentifier"
    private let kDebugLogging = "debugLogging"
    private let kOnboardingDone = "onboardingDone"
    private let kAutoGrade = "autoGrade"
    private let kSessionCap = "sessionCap"
    private let kIncludeNotDue = "includeNotDue"
    private let kReminderOn = "reminderOn"
    private let kReminderMinutes = "reminderMinutes"

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

    var librarySort: LibrarySort {
        didSet { defaults.set(librarySort.rawValue, forKey: kLibrarySort) }
    }

    /// Speech-to-text language (S-5); nil follows the device.
    var sttLocaleIdentifier: String? {
        didSet {
            if let id = sttLocaleIdentifier { defaults.set(id, forKey: kSTTLocale) } else { defaults.removeObject(forKey: kSTTLocale) }
        }
    }

    var sttLocale: Locale {
        sttLocaleIdentifier.map(Locale.init(identifier:)) ?? .current
    }

    /// Debug logging to a file (S-14). Off by default; see `DebugLogFile`.
    var debugLogging: Bool {
        didSet {
            defaults.set(debugLogging, forKey: kDebugLogging)
            Log.file.isEnabled = debugLogging
        }
    }

    /// Auto-grade spoken answers with AI (S-3). Takes effect only when a grading endpoint exists.
    var autoGrade: Bool {
        didSet { defaults.set(autoGrade, forKey: kAutoGrade) }
    }

    /// Quiz session cap, 10–100 (S-11).
    var sessionCap: Int {
        didSet { defaults.set(sessionCap, forKey: kSessionCap) }
    }

    /// Quiz sessions also include cards that aren't due yet (§10).
    var includeNotDue: Bool {
        didSet { defaults.set(includeNotDue, forKey: kIncludeNotDue) }
    }

    /// Daily due reminder (S-12): off, or a time of day in minutes after midnight.
    var reminderOn: Bool {
        didSet { defaults.set(reminderOn, forKey: kReminderOn) }
    }

    var reminderMinutes: Int {
        didSet { defaults.set(reminderMinutes, forKey: kReminderMinutes) }
    }

    /// Onboarding (F-60) is shown once.
    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: kOnboardingDone) }
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
        self.librarySort = LibrarySort(rawValue: defaults.string(forKey: kLibrarySort) ?? "") ?? .recent
        self.sttLocaleIdentifier = defaults.string(forKey: kSTTLocale)
        self.debugLogging = defaults.bool(forKey: kDebugLogging)
        self.onboardingDone = defaults.bool(forKey: kOnboardingDone)
        self.autoGrade = defaults.object(forKey: kAutoGrade) as? Bool ?? true
        self.sessionCap = min(100, max(10, defaults.object(forKey: kSessionCap) as? Int ?? 20))
        self.includeNotDue = defaults.bool(forKey: kIncludeNotDue)
        self.reminderOn = defaults.bool(forKey: kReminderOn)
        self.reminderMinutes = defaults.object(forKey: kReminderMinutes) as? Int ?? 18 * 60
        Log.file.isEnabled = debugLogging
    }
}
