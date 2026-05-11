import Foundation

@MainActor
@Observable
final class ProviderRegistry {
    static let shared = ProviderRegistry()

    private let defaults: UserDefaults
    private let kGenerationProvider = "providerForGeneration"
    private let kGradingProvider = "providerForGrading"

    var generationProvider: ProviderID {
        didSet { defaults.set(generationProvider.rawValue, forKey: kGenerationProvider) }
    }

    var gradingProvider: ProviderID {
        didSet { defaults.set(gradingProvider.rawValue, forKey: kGradingProvider) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let defaultID = AppleFoundationProvider().isAvailable ? ProviderID.appleFoundation : .claude
        let g = defaults.string(forKey: kGenerationProvider).flatMap { ProviderID(rawValue: $0) } ?? defaultID
        let j = defaults.string(forKey: kGradingProvider).flatMap { ProviderID(rawValue: $0) } ?? defaultID
        self.generationProvider = g
        self.gradingProvider = j
    }

    func provider(for purpose: ProviderPurpose) -> LLMProvider {
        let id: ProviderID = (purpose == .generation) ? generationProvider : gradingProvider
        return makeProvider(for: id)
    }

    func makeProvider(for id: ProviderID) -> LLMProvider {
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
        let id: ProviderID = (purpose == .generation) ? generationProvider : gradingProvider
        switch id {
        case .appleFoundation:
            let p = AppleFoundationProvider()
            return p.isAvailable ? nil : .providerUnavailable(.appleFoundation, p.unavailableReason)
        case .claude, .openAI:
            guard let account = id.keychainAccount,
                  let key = KeychainStore.get(account), !key.isEmpty
            else { return .missingAPIKey(id) }
            _ = key
            return nil
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
        (key(for: provider) ?? "").isEmpty == false
    }
}
