import Foundation
import AIQuizCore

/// Which provider serves each purpose, plus key management.
/// Injected through the SwiftUI environment; `.shared` exists only for the composition root.
/// Replaced by `AIRouter` in PLAN Phase 1.
@MainActor
@Observable
final class ProviderRegistry {
    static let shared: ProviderRegistry = {
        let env = AppEnvironment.current
        return ProviderRegistry(
            defaults: AppEnvironment.defaults,
            override: env.isUITest ? FakeProvider(scenario: env.scenario) : nil
        )
    }()

    private let defaults: UserDefaults
    /// When set, every purpose resolves to this provider and validation always passes
    /// (UI-test mode, DECISIONS ADR-005).
    private let override: LLMProvider?
    private let kGenerationProvider = "providerForGeneration"
    private let kGradingProvider = "providerForGrading"

    var generationProvider: ProviderID {
        didSet { defaults.set(generationProvider.rawValue, forKey: kGenerationProvider) }
    }

    var gradingProvider: ProviderID {
        didSet { defaults.set(gradingProvider.rawValue, forKey: kGradingProvider) }
    }

    init(defaults: UserDefaults = .standard, override: LLMProvider? = nil) {
        self.defaults = defaults
        self.override = override
        let defaultID = AppleFoundationProvider().isAvailable ? ProviderID.appleFoundation : .claude
        let g = defaults.string(forKey: kGenerationProvider).flatMap { ProviderID(rawValue: $0) } ?? defaultID
        let j = defaults.string(forKey: kGradingProvider).flatMap { ProviderID(rawValue: $0) } ?? defaultID
        self.generationProvider = g
        self.gradingProvider = j
    }

    var isOverridden: Bool { override != nil }

    func provider(for purpose: ProviderPurpose) -> LLMProvider {
        if let override { return override }
        let id: ProviderID = (purpose == .generation) ? generationProvider : gradingProvider
        return makeProvider(for: id)
    }

    func makeProvider(for id: ProviderID) -> LLMProvider {
        if let override { return override }
        switch id {
        case .appleFoundation:
            return AppleFoundationProvider()
        case .claude:
            return ClaudeProvider(apiKey: KeychainStore.get(id.keychainAccount ?? ""))
        case .openAI:
            return OpenAIProvider(apiKey: KeychainStore.get(id.keychainAccount ?? ""))
        }
    }

    /// Returns a typed error if the provider for `purpose` is missing required configuration.
    func validate(for purpose: ProviderPurpose) -> LLMError? {
        if override != nil { return nil }
        let id: ProviderID = (purpose == .generation) ? generationProvider : gradingProvider
        switch id {
        case .appleFoundation:
            let p = AppleFoundationProvider()
            return p.isAvailable ? nil : .providerUnavailable(.appleFoundation, p.unavailableReason)
        case .claude, .openAI:
            return hasKey(for: id) ? nil : .missingAPIKey(id)
        }
    }

    func setKey(_ value: String?, for provider: ProviderID) {
        guard let account = provider.keychainAccount else { return }
        KeychainStore.set(value, for: account)
    }

    func key(for provider: ProviderID) -> String? {
        guard let account = provider.keychainAccount else { return nil }
        return KeychainStore.get(account)
    }

    func hasKey(for provider: ProviderID) -> Bool {
        !(key(for: provider) ?? "").isEmpty
    }
}
