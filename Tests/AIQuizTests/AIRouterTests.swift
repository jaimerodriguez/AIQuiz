import XCTest
import LLMKit
import AIQuizCore
@testable import AIQuiz

@MainActor
final class AIRouterTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!

    override func setUp() async throws {
        suiteName = "AIRouterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = KeychainStore(service: "com.jaimer.aiquiz.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        keychain.clearAll()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let apple = AppleAvailability(isAvailable: true, reason: "")

    private func makeRouter(
        apple: AppleAvailability = .unavailable,
        factory: AIRouter.ClientFactory? = nil,
        now: @escaping () -> Date = Date.init
    ) -> AIRouter {
        AIRouter(defaults: defaults, keychain: keychain, appleAvailability: apple, factory: factory, now: now)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Persistence

    func testEndpointsRoutesAndKeysPersistAcrossInstances() {
        let router = makeRouter()
        let anthropic = EndpointPreset.anthropic.make()
        var ollama = EndpointPreset.ollama.make()
        ollama.model = "llama3.3"
        router.upsert(anthropic, apiKey: "sk-ant")
        router.upsert(ollama, apiKey: nil)
        router.setRoute(.grading, to: ollama.id)
        router.setFallback(.generation, to: ollama.id)

        let reloaded = makeRouter()
        XCTAssertEqual(reloaded.endpoints.map(\.name), ["Anthropic", "Ollama"])
        XCTAssertEqual(reloaded.endpoint(for: .grading)?.id, ollama.id)
        XCTAssertEqual(reloaded.endpoint(for: .generation)?.id, anthropic.id, "automatic route picks the first endpoint")
        XCTAssertEqual(reloaded.fallbackEndpoint(for: .generation)?.id, ollama.id)
        XCTAssertEqual(reloaded.key(for: reloaded.endpoints[0]), "sk-ant")
        XCTAssertNil(reloaded.key(for: reloaded.endpoints[1]))
    }

    func testUpsertNilKeepsKeyAndEmptyRemovesIt() {
        let router = makeRouter()
        var e = EndpointPreset.anthropic.make()
        router.upsert(e, apiKey: "first")
        e.name = "Renamed"
        router.upsert(e, apiKey: nil)
        XCTAssertEqual(router.key(for: router.endpoints[0]), "first")
        XCTAssertEqual(router.endpoints.count, 1)
        XCTAssertEqual(router.endpoints[0].name, "Renamed")
        router.upsert(router.endpoints[0], apiKey: "")
        XCTAssertNil(router.key(for: router.endpoints[0]))
    }

    func testDeleteRemovesKeyRoutesAndUsage() {
        let router = makeRouter()
        let e = EndpointPreset.anthropic.make()
        router.upsert(e, apiKey: "sk")
        router.setRoute(.chat, to: e.id)
        router.recordUsage(TokenUsage(input: 5, output: 5), for: e.id)
        let account = router.endpoints[0].keychainAccount!
        router.delete(e.id)
        XCTAssertTrue(router.endpoints.isEmpty)
        XCTAssertNil(router.explicitRoute(.chat))
        XCTAssertNil(keychain.get(account))
        XCTAssertNil(router.usage.perEndpoint[e.id.uuidString])
    }

    // MARK: v1 migration

    func testMigratesV1KeysAndProviderChoices() {
        keychain.set("sk-ant-v1", for: "anthropic_api_key")
        keychain.set("sk-oai-v1", for: "openai_api_key")
        defaults.set("claude", forKey: "providerForGeneration")
        defaults.set("openAI", forKey: "providerForGrading")

        let router = makeRouter(apple: apple)

        XCTAssertEqual(router.endpoints.map(\.kind), [.appleOnDevice, .anthropic, .openAICompatible])
        let anthropic = router.endpoints[1]
        let openAI = router.endpoints[2]
        XCTAssertEqual(anthropic.model, "claude-opus-5-5")
        XCTAssertEqual(router.key(for: anthropic), "sk-ant-v1")
        XCTAssertEqual(router.key(for: openAI), "sk-oai-v1")
        XCTAssertNil(keychain.get("anthropic_api_key"), "old account is removed")
        XCTAssertNil(keychain.get("openai_api_key"))
        XCTAssertEqual(router.endpoint(for: .generation)?.id, anthropic.id)
        XCTAssertEqual(router.endpoint(for: .summary)?.id, anthropic.id)
        XCTAssertEqual(router.endpoint(for: .grading)?.id, openAI.id)
        XCTAssertEqual(router.endpoint(for: .chat)?.id, openAI.id)
        XCTAssertEqual(router.issue(for: .grading), .noModel(endpoint: "OpenAI"), "no OpenAI model is hardcoded")
        XCTAssertNil(router.issue(for: .generation))
    }

    func testMigrationRunsOnlyOnce() {
        _ = makeRouter(apple: apple)
        keychain.set("late", for: "anthropic_api_key")
        let second = makeRouter(apple: apple)
        XCTAssertEqual(second.endpoints.map(\.kind), [.appleOnDevice])
    }

    func testFreshInstallWithAppleOnly() {
        let router = makeRouter(apple: apple)
        XCTAssertEqual(router.endpoint(for: .generation)?.kind, .appleOnDevice)
        XCTAssertNil(router.issue(for: .generation))
    }

    // MARK: Resolution and issues

    func testAutomaticRoutePrefersNonAppleEndpoints() {
        let router = makeRouter(apple: apple)
        router.upsert(EndpointPreset.anthropic.make(), apiKey: "k")
        XCTAssertEqual(router.endpoint(for: .generation)?.kind, .anthropic)
    }

    func testIssues() {
        let router = makeRouter()
        XCTAssertEqual(router.issue(for: .generation), .noEndpoint(.generation))
        XCTAssertThrowsError(try router.client(for: .generation))

        router.upsert(EndpointPreset.anthropic.make(), apiKey: nil)
        XCTAssertEqual(router.issue(for: .generation), .missingKey(endpoint: "Anthropic"))

        let unavailableApple = EndpointPreset.appleOnDevice.make()
        XCTAssertEqual(router.issue(for: unavailableApple), .unavailable(endpoint: "Apple on-device", reason: AppleAvailability.unavailable.reason))

        var local = EndpointPreset.ollama.make()
        XCTAssertEqual(router.issue(for: local), .noModel(endpoint: "Ollama"))
        local.model = "qwen"
        XCTAssertNil(router.issue(for: local), "local servers need no key")
    }

    // MARK: Clients, fallback, usage

    func testClientFallsBackAndMetersUsage() async throws {
        var primary = EndpointPreset.custom.make()
        primary.name = "Primary"
        primary.model = "p"
        primary.baseURL = URL(string: "http://primary.local/v1")
        var backup = EndpointPreset.custom.make()
        backup.name = "Backup"
        backup.model = "b"
        backup.baseURL = URL(string: "http://backup.local/v1")
        let primaryID = primary.id

        let router = makeRouter(factory: { endpoint, _, _ in
            if endpoint.id == primaryID {
                return FakeLLMClient.scripted([.failure(.server(status: 503))], endpoint: endpoint)
            }
            return FakeLLMClient(endpoint: endpoint) { _ in "from backup" }
        })
        router.upsert(primary, apiKey: nil)
        router.upsert(backup, apiKey: nil)
        router.setRoute(.generation, to: primary.id)
        router.setFallback(.generation, to: backup.id)

        let client = try router.client(for: .generation)
        let response = try await client.complete(ChatRequest(system: "s", messages: [.user("12345678")]))
        XCTAssertEqual(response.text, "from backup")

        await waitUntil { router.usage(for: backup).output > 0 }
        XCTAssertEqual(router.usage(for: backup).output, 3)
        XCTAssertEqual(router.usage(for: primary), .zero)
    }

    func testUsageRollsOverMonthlyAndEstimatesCost() {
        var current = Date(timeIntervalSince1970: 1_790_000_000)
        let router = makeRouter(now: { current })
        let e = EndpointPreset.anthropic.make()
        router.upsert(e, apiKey: "k")
        router.recordUsage(TokenUsage(input: 500_000, output: 100_000), for: e.id)
        XCTAssertEqual(router.estimatedCost(for: router.endpoints[0])!, 0.5 * 4 + 0.1 * 20, accuracy: 0.0001)

        current = current.addingTimeInterval(40 * 86_400)
        XCTAssertEqual(router.usage(for: e), .zero)
    }

    func testLearnedJSONSchemaSupportIsPersisted() {
        let router = makeRouter()
        var e = EndpointPreset.lmStudio.make()
        e.model = "m"
        router.upsert(e, apiKey: nil)
        XCTAssertTrue(router.endpoints[0].supportsJSONSchema)
        router.recordJSONSchemaSupport(false, for: e.id)
        XCTAssertFalse(makeRouter().endpoints[0].supportsJSONSchema)
    }

    func testConnectionUsesDraftSettingsAndRequiresAnthropicKey() async throws {
        let router = makeRouter(factory: { endpoint, _, _ in
            FakeLLMClient(endpoint: endpoint, models: ["m1", "m2", "m3"]) { _ in "" }
        })
        var local = EndpointPreset.ollama.make()
        local.baseURL = URL(string: "http://10.0.0.2:11434/v1")
        let models = try await router.testConnection(local, apiKey: nil)
        XCTAssertEqual(models, ["m1", "m2", "m3"])

        do {
            _ = try await router.testConnection(EndpointPreset.anthropic.make(), apiKey: "")
            XCTFail("expected missing key")
        } catch let error as LLMError {
            XCTAssertEqual(error, .missingAPIKey(endpoint: "Anthropic"))
        }
    }

    func testSummaryText() {
        let router = makeRouter()
        XCTAssertEqual(router.summary(for: .generation), "Not set up")
        router.upsert(EndpointPreset.anthropic.make(), apiKey: "k")
        XCTAssertEqual(router.summary(for: .generation), "Anthropic · claude-opus-5-5")
    }

    func testUITestFixturesServeTaskSpecificResponses() async throws {
        let handler = UITestAIFixtures.handler(scenario: .standard)
        let quiz = try await handler(ChatRequest(system: "", messages: [], responseFormat: ResponseFormat(name: "quiz", schema: QuizGenerator.schema)))
        XCTAssertTrue(quiz.contains("Fake Generated Quiz"))
        let judge = try await handler(ChatRequest(system: "", messages: [], responseFormat: ResponseFormat(name: "judge", schema: AnswerJudge.schema)))
        XCTAssertTrue(judge.contains("partial"))

        do {
            _ = try await UITestAIFixtures.handler(scenario: .endpointError)(ChatRequest(system: "", messages: []))
            XCTFail("expected error")
        } catch let error as LLMError {
            XCTAssertEqual(error, .server(status: 503))
        }
    }
}
