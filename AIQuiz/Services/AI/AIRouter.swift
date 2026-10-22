import Foundation
import Observation
import LLMKit

/// Owns the configured endpoints, which endpoint serves each purpose, API keys (via the
/// Keychain) and token usage (SPEC §7.5, §8.1, §8.2). Hands out ready-to-use clients that are
/// metered and wrapped with the purpose's fallback.
@MainActor
@Observable
final class AIRouter {
    typealias ClientFactory = @MainActor (_ endpoint: LLMEndpoint, _ apiKey: String?, _ router: AIRouter) -> LLMClient

    struct Routing: Codable, Equatable {
        var primary: [String: UUID] = [:]
        var fallback: [String: UUID] = [:]
    }

    struct UsageBook: Codable, Equatable {
        var month: String
        var perEndpoint: [String: TokenUsage] = [:]
    }

    /// Why a purpose can't run yet. Shown on the lazy setup sheet.
    enum SetupIssue: LocalizedError, Equatable {
        case noEndpoint(AIPurpose)
        case missingKey(endpoint: String)
        case noModel(endpoint: String)
        case unavailable(endpoint: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .noEndpoint(let purpose):
                return "Add an AI endpoint to use \(purpose.label.lowercased())."
            case .missingKey(let name):
                return "\(name) needs an API key."
            case .noModel(let name):
                return "\(name) has no model selected. Tap it, then Test connection and pick a model."
            case .unavailable(let name, let reason):
                return "\(name) is unavailable: \(reason)"
            }
        }
    }

    static let endpointsKey = "ai.endpoints.v2"
    static let routingKey = "ai.routing.v2"
    static let usageKey = "ai.usage.v2"

    private(set) var endpoints: [LLMEndpoint] = []
    private(set) var routing = Routing()
    private(set) var usage: UsageBook

    let appleAvailability: AppleAvailability
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let factory: ClientFactory
    private let now: () -> Date

    init(
        defaults: UserDefaults,
        keychain: KeychainStore,
        appleAvailability: AppleAvailability,
        factory: ClientFactory? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.appleAvailability = appleAvailability
        self.factory = factory ?? AIRouter.productionFactory
        self.now = now
        self.usage = UsageBook(month: AIRouter.monthKey(now()))

        if let data = defaults.data(forKey: Self.endpointsKey),
           let saved = try? JSONDecoder().decode([LLMEndpoint].self, from: data) {
            endpoints = saved
            if let r = defaults.data(forKey: Self.routingKey), let decoded = try? JSONDecoder().decode(Routing.self, from: r) {
                routing = decoded
            }
            if let u = defaults.data(forKey: Self.usageKey), let decoded = try? JSONDecoder().decode(UsageBook.self, from: u) {
                usage = decoded
            }
        } else {
            migrateFromV1()
        }
    }

    // MARK: Environment wiring

    static func makeForCurrentEnvironment() -> AIRouter {
        let env = AppEnvironment.current
        guard env.isUITest else {
            return AIRouter(
                defaults: AppEnvironment.defaults,
                keychain: .production,
                appleAvailability: AppleOnDeviceClient.availability()
            )
        }
        let keychain = KeychainStore.uiTest
        keychain.clearAll()
        let router = AIRouter(
            defaults: AppEnvironment.defaults,
            keychain: keychain,
            appleAvailability: .unavailable,
            factory: UITestAIFixtures.factory(scenario: env.scenario)
        )
        if env.scenario != .noEndpoints && router.endpoints.isEmpty {
            router.upsert(.fake(), apiKey: nil)
        }
        return router
    }

    static let productionFactory: ClientFactory = { endpoint, apiKey, router in
        switch endpoint.kind {
        case .anthropic:
            return AnthropicClient(endpoint: endpoint, apiKey: apiKey ?? "")
        case .openAICompatible:
            let id = endpoint.id
            return OpenAICompatibleClient(endpoint: endpoint, apiKey: apiKey) { [weak router] supported in
                Task { @MainActor in router?.recordJSONSchemaSupport(supported, for: id) }
            }
        case .appleOnDevice:
            return AppleOnDeviceClient(endpoint: endpoint)
        case .fake:
            return FakeLLMClient(endpoint: endpoint) { _ in "{}" }
        }
    }

    // MARK: Resolution

    /// Explicit route, else the first cloud or local-network endpoint, else Apple on-device.
    func endpoint(for purpose: AIPurpose) -> LLMEndpoint? {
        if let id = routing.primary[purpose.rawValue], let e = endpoints.first(where: { $0.id == id }) {
            return e
        }
        return endpoints.first(where: { $0.kind != .appleOnDevice }) ?? endpoints.first
    }

    func fallbackEndpoint(for purpose: AIPurpose) -> LLMEndpoint? {
        guard let id = routing.fallback[purpose.rawValue],
              let e = endpoints.first(where: { $0.id == id }),
              e.id != endpoint(for: purpose)?.id
        else { return nil }
        return e
    }

    func issue(for purpose: AIPurpose) -> SetupIssue? {
        guard let e = endpoint(for: purpose) else { return .noEndpoint(purpose) }
        return issue(for: e)
    }

    func issue(for e: LLMEndpoint) -> SetupIssue? {
        switch e.kind {
        case .anthropic:
            if !hasKey(for: e) { return .missingKey(endpoint: e.name) }
            if e.model.trimmingCharacters(in: .whitespaces).isEmpty { return .noModel(endpoint: e.name) }
        case .openAICompatible:
            if e.model.trimmingCharacters(in: .whitespaces).isEmpty { return .noModel(endpoint: e.name) }
        case .appleOnDevice:
            if !appleAvailability.isAvailable { return .unavailable(endpoint: e.name, reason: appleAvailability.reason) }
        case .fake:
            break
        }
        return nil
    }

    /// A metered client for the purpose, wrapped with its fallback when one is configured and usable.
    func client(for purpose: AIPurpose) throws -> LLMClient {
        guard let primary = endpoint(for: purpose) else { throw SetupIssue.noEndpoint(purpose) }
        if let issue = issue(for: primary) { throw issue }
        let client = meteredClient(for: primary)
        if let fallback = fallbackEndpoint(for: purpose), issue(for: fallback) == nil {
            return FallbackClient(primary: client, fallback: meteredClient(for: fallback))
        }
        return client
    }

    /// "Anthropic · claude-opus-5-5" for footers, or "Not set up".
    func summary(for purpose: AIPurpose) -> String {
        guard let e = endpoint(for: purpose) else { return "Not set up" }
        return e.model.isEmpty ? e.name : "\(e.name) · \(e.model)"
    }

    private func meteredClient(for endpoint: LLMEndpoint) -> LLMClient {
        let base = factory(endpoint, key(for: endpoint), self)
        return MeteredClient(base) { [weak self] endpoint, usage in
            Task { @MainActor in self?.recordUsage(usage, for: endpoint.id) }
        }
    }

    // MARK: Editing

    /// Insert or replace an endpoint. `apiKey`: nil keeps the stored key, "" removes it.
    func upsert(_ endpoint: LLMEndpoint, apiKey: String?) {
        var e = endpoint
        if e.keychainAccount == nil {
            e.keychainAccount = "endpoint.\(e.id.uuidString)"
        }
        if let apiKey, let account = e.keychainAccount {
            keychain.set(apiKey.isEmpty ? nil : apiKey, for: account)
        }
        if let i = endpoints.firstIndex(where: { $0.id == e.id }) {
            endpoints[i] = e
        } else {
            endpoints.append(e)
        }
        persist()
    }

    func delete(_ id: UUID) {
        if let e = endpoints.first(where: { $0.id == id }), let account = e.keychainAccount {
            keychain.set(nil, for: account)
        }
        endpoints.removeAll { $0.id == id }
        routing.primary = routing.primary.filter { $0.value != id }
        routing.fallback = routing.fallback.filter { $0.value != id }
        usage.perEndpoint[id.uuidString] = nil
        persist()
    }

    func setRoute(_ purpose: AIPurpose, to id: UUID?) {
        routing.primary[purpose.rawValue] = id
        persist()
    }

    func setFallback(_ purpose: AIPurpose, to id: UUID?) {
        routing.fallback[purpose.rawValue] = id
        persist()
    }

    func explicitRoute(_ purpose: AIPurpose) -> UUID? {
        routing.primary[purpose.rawValue]
    }

    func explicitFallback(_ purpose: AIPurpose) -> UUID? {
        routing.fallback[purpose.rawValue]
    }

    func key(for endpoint: LLMEndpoint) -> String? {
        endpoint.keychainAccount.flatMap(keychain.get)
    }

    func hasKey(for endpoint: LLMEndpoint) -> Bool {
        !(key(for: endpoint) ?? "").isEmpty
    }

    func clearAllKeys() {
        keychain.clearAll()
    }

    /// Result of checking an endpoint with (possibly unsaved) settings.
    struct Verification: Equatable, Sendable {
        /// Chat-capable models the endpoint offers.
        var models: [String]
        /// The model that answered the hello, or the one that would have if a model were set.
        var model: String
        /// The model's reply, or nil when no model was selected so no hello was sent.
        var reply: String?
        var seconds: Double?
    }

    /// The connectivity check sent on Test connection and when a new key is saved (CR-005).
    /// A few tokens at low effort; not counted in usage.
    static let helloRequest = ChatRequest(
        system: "This is a connectivity check from the AIQuiz app.",
        messages: [.user("Reply with only the word: hello")],
        maxTokens: 1_024,
        effort: .low,
        timeout: 45
    )

    /// Lists the endpoint's chat models, picks one if none is set (except on OpenAI and
    /// OpenRouter, whose lists are too long to guess from), then sends a hello and times the reply.
    func verify(_ endpoint: LLMEndpoint, apiKey: String?) async throws -> Verification {
        let key = (apiKey?.isEmpty ?? true) ? self.key(for: endpoint) : apiKey
        if endpoint.kind == .anthropic, (key ?? "").isEmpty {
            throw LLMError.missingAPIKey(endpoint: endpoint.name)
        }
        let models = ModelListFilter.chatModels(try await factory(endpoint, key, self).listModels())

        var target = endpoint
        let host = endpoint.baseURL?.host ?? ""
        let longCatalogue = host == "api.openai.com" || host.hasSuffix("openrouter.ai")
        if target.model.trimmingCharacters(in: .whitespaces).isEmpty, !longCatalogue, let first = models.first {
            target.model = first
        }
        guard !target.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Verification(models: models, model: "", reply: nil, seconds: nil)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let response = try await factory(target, key, self).complete(Self.helloRequest)
        let elapsed = start.duration(to: clock.now)
        let reply = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            throw LLMError.malformedResponse("the model returned an empty reply")
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        Log.ai.info("verified \(target.name) model \(target.model) in \(String(format: "%.2f", seconds))s")
        return Verification(models: models, model: target.model, reply: String(reply.prefix(60)), seconds: seconds)
    }

    func recordJSONSchemaSupport(_ supported: Bool, for id: UUID) {
        guard let i = endpoints.firstIndex(where: { $0.id == id }), endpoints[i].supportsJSONSchema != supported else { return }
        endpoints[i].supportsJSONSchema = supported
        persist()
        Log.ai.info("endpoint \(endpoints[i].name) json_schema support: \(supported)")
    }

    // MARK: Usage

    func recordUsage(_ u: TokenUsage, for id: UUID) {
        rollMonthIfNeeded()
        usage.perEndpoint[id.uuidString, default: .zero] = usage.perEndpoint[id.uuidString, default: .zero] + u
        persist()
    }

    func usage(for endpoint: LLMEndpoint) -> TokenUsage {
        rollMonthIfNeeded()
        return usage.perEndpoint[endpoint.id.uuidString] ?? .zero
    }

    func estimatedCost(for endpoint: LLMEndpoint) -> Double? {
        guard let input = endpoint.priceInPerMTok, let output = endpoint.priceOutPerMTok else { return nil }
        return usage(for: endpoint).cost(inPerMTok: input, outPerMTok: output)
    }

    func resetUsage() {
        usage = UsageBook(month: Self.monthKey(now()))
        persist()
    }

    private func rollMonthIfNeeded() {
        let current = Self.monthKey(now())
        if usage.month != current {
            usage = UsageBook(month: current)
        }
    }

    static func monthKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: Persistence and migration

    private func persist() {
        let encoder = JSONEncoder()
        if let d = try? encoder.encode(endpoints) { defaults.set(d, forKey: Self.endpointsKey) }
        if let d = try? encoder.encode(routing) { defaults.set(d, forKey: Self.routingKey) }
        if let d = try? encoder.encode(usage) { defaults.set(d, forKey: Self.usageKey) }
    }

    /// First launch of 1.1.0: turn v1's fixed providers into endpoints, move their keys to
    /// per-endpoint Keychain accounts, and carry the v1 generation/grading choices over as routes.
    private func migrateFromV1() {
        var created: [String: UUID] = [:]

        if appleAvailability.isAvailable {
            let apple = EndpointPreset.appleOnDevice.make()
            endpoints.append(apple)
            created["appleFoundation"] = apple.id
        }
        if let key = keychain.get("anthropic_api_key"), !key.isEmpty {
            var e = EndpointPreset.anthropic.make()
            e.keychainAccount = "endpoint.\(e.id.uuidString)"
            keychain.set(key, for: e.keychainAccount!)
            keychain.set(nil, for: "anthropic_api_key")
            endpoints.append(e)
            created["claude"] = e.id
        }
        if let key = keychain.get("openai_api_key"), !key.isEmpty {
            var e = EndpointPreset.openAI.make()
            e.keychainAccount = "endpoint.\(e.id.uuidString)"
            keychain.set(key, for: e.keychainAccount!)
            keychain.set(nil, for: "openai_api_key")
            endpoints.append(e)
            created["openAI"] = e.id
        }

        if let v1 = defaults.string(forKey: "providerForGeneration"), let id = created[v1] {
            routing.primary[AIPurpose.generation.rawValue] = id
            routing.primary[AIPurpose.summary.rawValue] = id
        }
        if let v1 = defaults.string(forKey: "providerForGrading"), let id = created[v1] {
            routing.primary[AIPurpose.grading.rawValue] = id
            routing.primary[AIPurpose.chat.rawValue] = id
        }
        persist()
        if !created.isEmpty {
            Log.ai.info("migrated v1 providers: \(created.keys.sorted().joined(separator: ", "))")
        }
    }
}
