import Foundation
import FoundationModels
import LLMKit

/// Apple's on-device model as an `LLMClient` (SPEC §8.4). Text only; structured output is
/// requested in the instructions and read back with the tolerant parser. The context window is
/// about 4k tokens, so inputs over 80 % of it are rejected up front.
struct AppleOnDeviceClient: LLMClient {
    let endpoint: LLMEndpoint

    static func availability() -> AppleAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AppleAvailability(isAvailable: true, reason: "")
        case .unavailable(let reason):
            return AppleAvailability(isAvailable: false, reason: describe(reason))
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again later."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let availability = Self.availability()
        guard availability.isAvailable else {
            throw LLMError.endpointUnavailable(availability.reason)
        }
        if request.estimatedInputTokens > Int(Double(endpoint.contextWindowTokens) * 0.8) {
            throw LLMError.contextTooLong
        }

        var instructions = request.system
        if let format = request.responseFormat {
            instructions += "\n\nRespond with only a JSON object (no prose, no code fences) that matches this JSON Schema:\n"
                + format.schema.promptText
        }
        let prompt = request.messages.map(\.text).joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content
            let usage = TokenUsage(input: request.estimatedInputTokens, output: (text.utf8.count + 3) / 4)
            return ChatResponse(text: text, usage: usage, stopReason: .endTurn, model: endpoint.model)
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw LLMError.contextTooLong
            case .guardrailViolation:
                throw LLMError.refused(category: "guardrail")
            default:
                throw LLMError.endpointUnavailable(error.localizedDescription)
            }
        } catch {
            throw LLMError.endpointUnavailable(error.localizedDescription)
        }
    }

    func listModels() async throws -> [String] {
        let availability = Self.availability()
        guard availability.isAvailable else {
            throw LLMError.endpointUnavailable(availability.reason)
        }
        return [endpoint.model]
    }
}
