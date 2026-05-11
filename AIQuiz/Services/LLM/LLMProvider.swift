import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case appleFoundation
    case claude
    case openAI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleFoundation: return "Apple on-device"
        case .claude: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .appleFoundation: return false
        case .claude, .openAI: return true
        }
    }

    var keychainAccount: String? {
        switch self {
        case .openAI: return "openai_api_key"
        case .claude: return "anthropic_api_key"
        case .appleFoundation: return nil
        }
    }
}

enum ProviderPurpose: String, Codable, CaseIterable {
    case generation
    case grading
}

struct QuizGenRequest: Sendable {
    enum Source: Sendable {
        case topic
        case markdown
        case article
    }
    var source: Source
    var topic: String
    var sourceContent: String?
    var cardCount: Int?
    var difficulty: String?
    var language: String?
    var tone: String?
    var focus: String?
    var exclude: String?
}

struct JudgeRequest: Sendable {
    var prompt: String
    var userAnswer: String
    var correctShort: String?
    var correctLong: String
}

struct JudgeVerdict: Sendable {
    var verdict: CardVerdict
    var reason: String
}

enum LLMError: LocalizedError {
    case noProviderConfigured
    case missingAPIKey(ProviderID)
    case providerUnavailable(ProviderID, String)
    case requestFailed(String)
    case malformedResponse(String)
    case sourceTooLong(provider: ProviderID, characters: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No AI provider is configured. Choose one in Settings."
        case .missingAPIKey(let p):
            return "\(p.label) needs an API key. Add one in Settings."
        case .providerUnavailable(let p, let reason):
            return "\(p.label) is unavailable: \(reason)"
        case .requestFailed(let msg):
            return msg
        case .malformedResponse(let msg):
            return "Couldn't read the model's response: \(msg)"
        case .sourceTooLong(let p, let chars, let limit):
            return "Source is too long for \(p.label) (\(chars) chars, limit \(limit)). Try a shorter source or a different provider."
        }
    }
}

protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    var isAvailable: Bool { get }
    var maxSourceCharacters: Int { get }
    func generateQuiz(_ req: QuizGenRequest) async throws -> QuizPayload
    func judgeAnswer(_ req: JudgeRequest) async throws -> JudgeVerdict
}

extension LLMProvider {
    func enforceLimit(_ content: String?) throws {
        guard let content else { return }
        if content.count > maxSourceCharacters {
            throw LLMError.sourceTooLong(provider: id, characters: content.count, limit: maxSourceCharacters)
        }
    }
}
