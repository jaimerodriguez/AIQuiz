import SwiftUI
import LLMKit

/// Add or edit one endpoint: name, address, key, model, limits, prices.
///
/// The key field is visible by default so paste mistakes are easy to spot, with a toggle to
/// hide it (CR-005). Test connection, and saving a newly entered key, send a short hello to
/// the model and show its reply.
struct EndpointEditView: View {
    let original: LLMEndpoint
    let isNew: Bool

    @Environment(AIRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LLMEndpoint
    @State private var baseURLText: String
    @State private var keyDraft = ""
    @State private var keyVisible = true
    @State private var savedKeyRevealed = false
    @State private var savedKeyRemoved = false
    @State private var models: [String] = []
    @State private var testState: TestState = .idle
    /// Settings that last passed verification, so Save does not re-send the hello.
    @State private var verifiedFingerprint: String?
    @State private var saveFailure: String?

    enum TestState: Equatable {
        case idle
        case testing
        case success(AIRouter.Verification)
        case failure(String)
    }

    init(original: LLMEndpoint, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
        _baseURLText = State(initialValue: original.baseURL?.absoluteString ?? "")
    }

    private var storedKey: String? { isNew || savedKeyRemoved ? nil : router.key(for: original) }
    private var usesNetwork: Bool { draft.kind == .anthropic || draft.kind == .openAICompatible }
    private var normalizedKey: String { APIKeyCheck.normalize(keyDraft) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("endpoints.name")
                if usesNetwork {
                    TextField("Base URL", text: $baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("endpoints.baseURL")
                    keyField
                    if let storedKey, keyDraft.isEmpty {
                        savedKeyRow(storedKey)
                    }
                }
            } header: {
                Text("Endpoint")
            } footer: {
                if usesNetwork {
                    Text(storedKey == nil
                         ? "Paste your key. It's checked with a short hello before saving."
                         : "Paste a new key to replace the saved one. It's checked with a short hello before saving.")
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
                    Task { await runTest() }
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
                Text("Test connection lists the models this endpoint offers and sends the selected model a one-word hello. It uses a few tokens.")
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
                Button("Save") { Task { await save() } }
                    .disabled(!canSave || testState == .testing)
                    .accessibilityIdentifier("endpoints.save")
            }
        }
        .onChange(of: draft.model) { _, model in
            if draft.kind == .anthropic, let price = AnthropicPricing.price(for: model) {
                draft.priceInPerMTok = price.input
                draft.priceOutPerMTok = price.output
            }
        }
        .alert("Couldn't confirm this key", isPresented: Binding(
            get: { saveFailure != nil },
            set: { if !$0 { saveFailure = nil } }
        )) {
            Button("Save anyway", role: .destructive) { commit() }
                .accessibilityIdentifier("endpoints.saveAnyway")
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(saveFailure ?? "")
        }
    }

    // MARK: Key entry

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Group {
                    if keyVisible {
                        TextField(keyPlaceholder, text: $keyDraft, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.body.monospaced())
                    } else {
                        SecureField(keyPlaceholder, text: $keyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("endpoints.key")

                Button {
                    keyVisible.toggle()
                } label: {
                    Image(systemName: keyVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(keyVisible ? "Hide key" : "Show key")
                .accessibilityIdentifier("endpoints.keyVisibility")
            }
            if let warning = APIKeyCheck.warning(for: normalizedKey, kind: draft.kind, baseURL: resolvedBaseURL) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("endpoints.keyWarning")
            }
        }
    }

    private func savedKeyRow(_ key: String) -> some View {
        HStack {
            LabeledContent("Saved key") {
                Text(savedKeyRevealed ? key : APIKeyCheck.masked(key))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(savedKeyRevealed ? 3 : 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("endpoints.savedKey")
            Button {
                savedKeyRevealed.toggle()
            } label: {
                Image(systemName: savedKeyRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(savedKeyRevealed ? "Hide saved key" : "Show saved key")
            Button("Remove", role: .destructive) {
                router.upsert(original, apiKey: "")
                savedKeyRemoved = true
            }
            .buttonStyle(.borderless)
        }
    }

    private var keyPlaceholder: String {
        draft.kind == .anthropic ? "API key (sk-ant-…)" : "API key (optional for local servers)"
    }

    // MARK: Status

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success(let v):
            VStack(alignment: .leading, spacing: 2) {
                if let reply = v.reply {
                    Label("\(v.model) replied “\(reply)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(v.models.count) model\(v.models.count == 1 ? "" : "s") available · \(String(format: "%.1f", v.seconds ?? 0)) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Connected · \(v.models.count) model\(v.models.count == 1 ? "" : "s") available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Pick a model, then test again to send it a hello.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    // MARK: Actions

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

    private var fingerprint: String {
        let e = endpointForSaving
        return [e.baseURL?.absoluteString ?? "", e.model, normalizedKey].joined(separator: "|")
    }

    /// Runs the check and applies its result to the form. Returns the failure message, if any.
    @discardableResult
    private func runTest() async -> String? {
        testState = .testing
        do {
            let v = try await router.verify(endpointForSaving, apiKey: normalizedKey)
            models = v.models
            if !v.model.isEmpty { draft.model = v.model }
            testState = .success(v)
            if v.reply != nil { verifiedFingerprint = fingerprint }
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testState = .failure(message)
            return message
        }
    }

    /// A newly entered key is verified before saving unless these exact settings already passed.
    private func save() async {
        if !normalizedKey.isEmpty, verifiedFingerprint != fingerprint {
            if let failure = await runTest() {
                saveFailure = failure
                return
            }
        }
        commit()
    }

    private func commit() {
        router.upsert(endpointForSaving, apiKey: normalizedKey.isEmpty ? nil : normalizedKey)
        dismiss()
    }
}
