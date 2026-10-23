import Foundation
import LLMKit

/// Starting points for new endpoints (SPEC §8.1). Users edit everything after picking one.
enum EndpointPreset: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case ollama
    case lmStudio
    case openRouter
    case custom
    case appleOnDevice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .ollama: return "Ollama (local network)"
        case .lmStudio: return "LM Studio (local network)"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom OpenAI-compatible"
        case .appleOnDevice: return "Apple on-device"
        }
    }

    var systemImage: String {
        switch self {
        case .anthropic, .openAI, .openRouter: return "cloud"
        case .ollama, .lmStudio: return "desktopcomputer"
        case .custom: return "server.rack"
        case .appleOnDevice: return "iphone"
        }
    }

    /// Presets offered in the Add menu. Apple on-device is only offered when available.
    static func addable(appleAvailable: Bool) -> [EndpointPreset] {
        allCases.filter { $0 != .appleOnDevice || appleAvailable }
    }

    func make() -> LLMEndpoint {
        switch self {
        case .anthropic:
            let price = AnthropicPricing.price(for: "claude-opus-5-5")
            return LLMEndpoint(
                kind: .anthropic, name: "Anthropic", baseURL: AnthropicClient.defaultBaseURL,
                model: "claude-opus-5-5", contextWindowTokens: 1_000_000,
                supportsJSONSchema: true, supportsVision: true,
                priceInPerMTok: price?.input, priceOutPerMTok: price?.output
            )
        case .openAI:
            return LLMEndpoint(
                kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1"),
                model: "", contextWindowTokens: 128_000, supportsJSONSchema: true, supportsVision: true
            )
        case .ollama:
            return LLMEndpoint(
                kind: .openAICompatible, name: "Ollama", baseURL: URL(string: "http://localhost:11434/v1"),
                model: "", contextWindowTokens: 32_768, supportsJSONSchema: true
            )
        case .lmStudio:
            return LLMEndpoint(
                kind: .openAICompatible, name: "LM Studio", baseURL: URL(string: "http://localhost:1234/v1"),
                model: "", contextWindowTokens: 32_768, supportsJSONSchema: true
            )
        case .openRouter:
            return LLMEndpoint(
                kind: .openAICompatible, name: "OpenRouter", baseURL: URL(string: "https://openrouter.ai/api/v1"),
                model: "", contextWindowTokens: 128_000, supportsJSONSchema: true
            )
        case .custom:
            return LLMEndpoint(
                kind: .openAICompatible, name: "Custom", baseURL: nil,
                model: "", contextWindowTokens: 32_768, supportsJSONSchema: true
            )
        case .appleOnDevice:
            return LLMEndpoint(
                kind: .appleOnDevice, name: "Apple on-device", model: "apple-on-device",
                contextWindowTokens: 4_096, supportsJSONSchema: false
            )
        }
    }
}

/// Published Anthropic list prices per million tokens (input, output), checked 2026-10-22.
/// Used to pre-fill an endpoint's price fields; users can edit them.
enum AnthropicPricing {
    static let table: [String: (input: Double, output: Double)] = [
        "claude-fable-5-1": (10, 50),
        "claude-opus-5-5": (4, 20),
        "claude-opus-5": (5, 25),
        "claude-sonnet-5-5": (2, 10),
        "claude-sonnet-5": (2, 10),
        "claude-haiku-5-5": (0.10, 0.50),
        "claude-haiku-4-5": (1, 5)
    ]

    static func price(for model: String) -> (input: Double, output: Double)? {
        table[model]
    }
}
