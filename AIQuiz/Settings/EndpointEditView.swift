import SwiftUI
import LLMKit

/// Add or edit one endpoint: name, address, key, model (from Test connection), limits, prices.
struct EndpointEditView: View {
    let original: LLMEndpoint
    let isNew: Bool

    @Environment(AIRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LLMEndpoint
    @State private var baseURLText: String
    @State private var keyDraft = ""
    @State private var models: [String] = []
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    init(original: LLMEndpoint, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
        _baseURLText = State(initialValue: original.baseURL?.absoluteString ?? "")
    }

    private var hasStoredKey: Bool { !isNew && router.hasKey(for: original) }
    private var usesNetwork: Bool { draft.kind == .anthropic || draft.kind == .openAICompatible }

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("endpoints.name")
                if usesNetwork {
                    TextField("Base URL", text: $baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("endpoints.baseURL")
                    SecureField(hasStoredKey ? "API key (saved; leave blank to keep)" : keyPlaceholder, text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("endpoints.key")
                    if hasStoredKey {
                        Button("Remove saved key", role: .destructive) {
                            router.upsert(original, apiKey: "")
                        }
                    }
                }
            }

            Section {
                TextField("Model id", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("endpoints.model")
                if !models.isEmpty {
                    Picker("Available models", selection: $draft.model) {
                        if !models.contains(draft.model) {
                            Text(draft.model.isEmpty ? "Choose…" : draft.model).tag(draft.model)
                        }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("endpoints.modelPicker")
                }
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "bolt.horizontal")
                        if testState == .testing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(testState == .testing || (usesNetwork && resolvedBaseURL == nil))
                .accessibilityIdentifier("endpoints.test")
                testStatus
            } header: {
                Text("Model")
            } footer: {
                Text("Test connection lists the models this endpoint offers.")
            }

            Section {
                Stepper(value: $draft.contextWindowTokens, in: 2_048...2_000_000, step: draft.contextWindowTokens >= 100_000 ? 50_000 : 2_048) {
                    LabeledContent("Context window", value: "\(draft.contextWindowTokens.formatted()) tokens")
                }
                .accessibilityIdentifier("endpoints.contextWindow")
                priceField("Input $ per million tokens", value: $draft.priceInPerMTok)
                priceField("Output $ per million tokens", value: $draft.priceOutPerMTok)
            } header: {
                Text("Limits and pricing")
            } footer: {
                Text("Sources larger than 80% of the context window are rejected before sending. Prices are only used to estimate cost.")
            }
        }
        .navigationTitle(isNew ? "Add endpoint" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("endpoints.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("endpoints.save")
            }
        }
        .onChange(of: draft.model) { _, model in
            if draft.kind == .anthropic, let price = AnthropicPricing.price(for: model) {
                draft.priceInPerMTok = price.input
                draft.priceOutPerMTok = price.output
            }
        }
    }

    private var keyPlaceholder: String {
        draft.kind == .anthropic ? "API key" : "API key (optional for local servers)"
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success(let count):
            Label("Connected · \(count) model\(count == 1 ? "" : "s") available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("endpoints.testResult")
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("endpoints.testResult")
        }
    }

    private func priceField(_ title: String, value: Binding<Double?>) -> some View {
        LabeledContent(title) {
            TextField("optional", value: value, format: .number.precision(.fractionLength(0...4)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }

    private var resolvedBaseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http"), url.host != nil else { return nil }
        return url
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !usesNetwork || resolvedBaseURL != nil
    }

    private var endpointForSaving: LLMEndpoint {
        var e = draft
        e.name = e.name.trimmingCharacters(in: .whitespaces)
        e.model = e.model.trimmingCharacters(in: .whitespaces)
        if usesNetwork { e.baseURL = resolvedBaseURL }
        return e
    }

    private func test() async {
        testState = .testing
        do {
            let found = try await router.testConnection(endpointForSaving, apiKey: keyDraft)
            models = found
            if draft.model.isEmpty, let first = found.first {
                draft.model = first
            }
            testState = .success(found.count)
        } catch {
            testState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func save() {
        router.upsert(endpointForSaving, apiKey: keyDraft.isEmpty ? nil : keyDraft)
        dismiss()
    }
}
