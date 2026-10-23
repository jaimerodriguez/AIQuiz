import XCTest
import AIQuizCore
@testable import AIQuiz

@MainActor
final class ProviderRegistryTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "ProviderRegistryTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testOverrideServesEveryPurposeAndPassesValidation() async throws {
        let registry = ProviderRegistry(defaults: freshDefaults(), override: FakeProvider(scenario: .standard))
        XCTAssertTrue(registry.isOverridden)
        XCTAssertNil(registry.validate(for: .generation))
        XCTAssertNil(registry.validate(for: .grading))

        let provider = registry.provider(for: .grading)
        let verdict = try await provider.judgeAnswer(JudgeRequest(prompt: "p", userAnswer: "a", correctLong: "l"))
        XCTAssertEqual(verdict.verdict, .partial)
    }

    func testFakeProviderGenerationFixture() async throws {
        let provider = FakeProvider(scenario: .standard)
        let quiz = try await provider.generateQuiz(QuizGenRequest(source: .topic, topic: "anything"))
        XCTAssertEqual(quiz.name, "Fake Generated Quiz")
        XCTAssertEqual(quiz.cards.count, 5)
    }

    func testFakeProviderErrorScenario() async {
        let provider = FakeProvider(scenario: .endpointError)
        do {
            _ = try await provider.generateQuiz(QuizGenRequest(source: .topic, topic: "x"))
            XCTFail("expected throw")
        } catch let error as LLMError {
            if case .requestFailed = error {} else { XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFakeProviderMalformedScenario() async {
        let provider = FakeProvider(scenario: .malformedJSON)
        do {
            _ = try await provider.judgeAnswer(JudgeRequest(prompt: "p", userAnswer: "a", correctLong: "l"))
            XCTFail("expected throw")
        } catch is LLMResponseParseError {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testSelectionPersistsInDefaults() {
        let defaults = freshDefaults()
        let registry = ProviderRegistry(defaults: defaults)
        registry.generationProvider = .openAI
        registry.gradingProvider = .claude
        let reloaded = ProviderRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.generationProvider, .openAI)
        XCTAssertEqual(reloaded.gradingProvider, .claude)
    }

    func testValidationWithoutKeyReportsMissingKey() throws {
        let registry = ProviderRegistry(defaults: freshDefaults())
        registry.gradingProvider = .claude
        // The test host has no key stored under the app's Keychain service.
        if registry.hasKey(for: .claude) { throw XCTSkip("a Claude key exists in this Keychain") }
        guard case .missingAPIKey(let id)? = registry.validate(for: .grading) else {
            return XCTFail("expected missingAPIKey")
        }
        XCTAssertEqual(id, .claude)
    }
}
