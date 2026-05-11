import SwiftUI

struct ProviderSettingsView: View {
    @Bindable private var registry = ProviderRegistry.shared
    @State private var openAIKeyDraft: String = ""
    @State private var claudeKeyDraft: String = ""
    @State private var showSavedToast: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Generation", selection: $registry.generationProvider) {
                    ForEach(visibleProviders) { provider($0) }
                }
                Picker("Grading", selection: $registry.gradingProvider) {
                    ForEach(visibleProviders) { provider($0) }
                }
            } header: {
                Text("AI provider")
            } footer: {
                Text("Generation creates new quizzes from a topic or source. Grading judges your spoken answers in Quiz mode.")
            }

            keysSection

            Section {
                Button(role: .destructive) {
                    KeychainStore.clearAll()
                    openAIKeyDraft = ""
                    claudeKeyDraft = ""
                } label: {
                    Label("Clear all API keys", systemImage: "trash")
                }
            }
        }
        .navigationTitle("AI providers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            openAIKeyDraft = registry.key(for: .openAI) ?? ""
            claudeKeyDraft = registry.key(for: .claude) ?? ""
        }
        .overlay(alignment: .top) {
            if showSavedToast {
                Text("Saved")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.green.opacity(0.15), in: Capsule())
                    .padding()
                    .transition(.opacity)
            }
        }
    }

    private var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { id in
            switch id {
            case .appleFoundation:
                return AppleFoundationProvider().isAvailable
            case .claude, .openAI:
                return true
            }
        }
    }

    @ViewBuilder
    private func provider(_ id: ProviderID) -> some View {
        Text(id.label).tag(id)
    }

    private var keysSection: some View {
        Section {
            keyField(label: "OpenAI", id: .openAI, draft: $openAIKeyDraft)
            keyField(label: "Anthropic Claude", id: .claude, draft: $claudeKeyDraft)
        } header: {
            Text("API keys")
        } footer: {
            Text("Keys are stored in the iOS Keychain on this device only. Apple on-device runs without a key on supported devices.")
        }
    }

    private func keyField(label: String, id: ProviderID, draft: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                if registry.hasKey(for: id) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            SecureField("Paste API key", text: draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    registry.setKey(draft.wrappedValue, for: id)
                    flashSaved()
                }
                .buttonStyle(.bordered)
                .disabled(draft.wrappedValue.isEmpty)
                if registry.hasKey(for: id) {
                    Button(role: .destructive) {
                        registry.setKey(nil, for: id)
                        draft.wrappedValue = ""
                    } label: {
                        Text("Remove")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func flashSaved() {
        withAnimation { showSavedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showSavedToast = false }
        }
    }
}
