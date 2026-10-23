import Foundation
import AIQuizCore

/// Replays JSON fixtures from `Resources/TestFixtures` instead of calling a model.
/// Installed by `ProviderRegistry` in UI-test mode (DECISIONS ADR-005).
/// Replaced by `FakeLLMClient` in PLAN Phase 1.
struct FakeProvider: LLMProvider {
    let scenario: AppEnvironment.Scenario

    var id: ProviderID { .openAI }
    var isAvailable: Bool { true }
    var maxSourceCharacters: Int { 100_000 }

    func generateQuiz(_ req: QuizGenRequest) async throws -> QuizPayload {
        try enforceLimit(req.sourceContent)
        try await simulateLatency()
        let raw = try fixture(named: "generation")
        return try LLMResponseParser.decode(raw, as: QuizFile.self).quiz
    }

    func judgeAnswer(_ req: JudgeRequest) async throws -> JudgeVerdict {
        try await simulateLatency()
        let raw = try fixture(named: "grading")
        let json: JudgeJSON = try LLMResponseParser.decode(raw)
        return json.toVerdict()
    }

    private func simulateLatency() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func fixture(named name: String) throws -> String {
        switch scenario {
        case .endpointError:
            throw LLMError.requestFailed("Fake endpoint error (scenario endpointError)")
        case .malformedJSON:
            return "{ this is not valid json"
        case .standard, .emptyLibrary:
            break
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "TestFixtures")
                ?? Bundle.main.url(forResource: name, withExtension: "json")
        else {
            throw LLMError.requestFailed("Missing test fixture \(name).json")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
