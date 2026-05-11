import AVFoundation
import Foundation

struct VoiceInfo: Identifiable, Hashable, Sendable {
    var id: String { identifier }
    let identifier: String
    let name: String
    let language: String
    let qualityRaw: Int

    var qualityLabel: String {
        switch qualityRaw {
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: return "Premium"
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: return "Enhanced"
        default: return "Default"
        }
    }

    var displayName: String {
        let locale = Locale(identifier: language)
        let languageLabel = locale.localizedString(forIdentifier: language) ?? language
        return "\(name) · \(languageLabel)"
    }
}

@MainActor
enum VoiceCatalog {
    static func all() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceInfo(
                identifier: $0.identifier,
                name: $0.name,
                language: $0.language,
                qualityRaw: $0.quality.rawValue
            )
        }
    }

    static func grouped() -> [(language: String, voices: [VoiceInfo])] {
        let voices = all().sorted { lhs, rhs in
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if lhs.qualityRaw != rhs.qualityRaw { return lhs.qualityRaw > rhs.qualityRaw }
            return lhs.name < rhs.name
        }
        var groups: [(String, [VoiceInfo])] = []
        for voice in voices {
            if let lastIdx = groups.indices.last, groups[lastIdx].0 == voice.language {
                groups[lastIdx].1.append(voice)
            } else {
                groups.append((voice.language, [voice]))
            }
        }
        return groups
    }

    static func info(forIdentifier id: String) -> VoiceInfo? {
        all().first { $0.identifier == id }
    }

    /// Best available voice for the given language code, preferring premium > enhanced > default.
    static func bestVoice(forLanguage language: String) -> VoiceInfo? {
        let lang = language.lowercased()
        let candidates = all().filter { $0.language.lowercased().hasPrefix(lang.prefix(2)) }
        return candidates.max { $0.qualityRaw < $1.qualityRaw }
    }

    static func bestVoiceForCurrentLocale() -> VoiceInfo? {
        let code = Locale.current.identifier
        if let v = bestVoice(forLanguage: code) { return v }
        return bestVoice(forLanguage: "en")
    }

    static var hasAnyPremiumOrEnhanced: Bool {
        all().contains { $0.qualityRaw >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue }
    }
}
