import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleFoundationProvider: LLMProvider {
    var id: ProviderID { .appleFoundation }
    var maxSourceCharacters: Int { 10_000 }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ""
            case .unavailable(let reason):
                return "Unavailable: \(String(describing: reason))"
            }
        }
        return "Requires iOS 26 or later."
        #else
        return "Apple Foundation Models framework not available in this build."
        #endif
    }

    func generateQuiz(_ req: QuizGenRequest) async throws -> QuizPayload {
        try enforceLimit(req.sourceContent)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let raw = try await respond(
                system: PromptBuilder.quizSystem(),
                user: PromptBuilder.quizUser(req)
            )
            do {
                return try LLMResponseParser.decode(raw, as: QuizFile.self).quiz
            } catch {
                let retry = try await respond(
                    system: PromptBuilder.quizSystem(),
                    user: PromptBuilder.quizUser(req) + "\n\nThe previous response could not be decoded: \(error.localizedDescription). Return only the JSON object exactly matching the schema."
                )
                return try LLMResponseParser.decode(retry, as: QuizFile.self).quiz
            }
        }
        #endif
        throw LLMError.providerUnavailable(.appleFoundation, unavailableReason)
    }

    func judgeAnswer(_ req: JudgeRequest) async throws -> JudgeVerdict {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let raw = try await respond(
                system: PromptBuilder.judgeSystem(),
                user: PromptBuilder.judgeUser(req)
            )
            let json: JudgeJSON = try LLMResponseParser.decode(raw)
            return json.toVerdict()
        }
        #endif
        throw LLMError.providerUnavailable(.appleFoundation, unavailableReason)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func respond(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            let response = try await session.respond(to: user)
            return response.content
        } catch {
            throw LLMError.requestFailed("Apple model: \(error.localizedDescription)")
        }
    }
    #endif
}
