import SwiftUI
import LLMKit

/// Settings → AI endpoints (SPEC S-1, S-2, S-16). Also used as the lazy setup sheet, with
/// `setupIssue` explaining why the user was sent here.
struct EndpointsListView: View {
    var setupIssue: String?
    var showsDoneButton = false

    @Environment(AIRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var confirmClearKeys = false

    struct EditTarget: Identifiable {
        let endpoint: LLMEndpoint
        let isNew: Bool
        var id: UUID { endpoint.id }
    }

    var body: some View {
        Form {
            if let setupIssue {
                Section {
                    Label(setupIssue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("endpoints.setupIssue")
                }
            }
            endpointsSection
            if !router.endpoints.isEmpty {
                routingSection
                usageSection
            }
            Section {
                Button(role: .destructive) {
                    confirmClearKeys = true
                } label: {
                    Label("Clear all API keys", systemImage: "key.slash")
                }
                .accessibilityIdentifier("endpoints.clearKeys")
            } footer: {
                Text("Keys are stored in the iOS Keychain on this device only and are sent only to the endpoint they belong to.")
            }
        }
        .navigationTitle("AI endpoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("endpoints.done")
                }
            }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                EndpointEditView(original: target.endpoint, isNew: target.isNew)
            }
        }
        .alert("Clear all API keys?", isPresented: $confirmClearKeys) {
            Button("Clear", role: .destructive) { router.clearAllKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Endpoints stay; you'll need to enter their keys again.")
        }
    }

    private var endpointsSection: some View {
        Section {
            ForEach(router.endpoints) { endpoint in
                Button {
                    editing = EditTarget(endpoint: endpoint, isNew: false)
                } label: {
                    endpointRow(endpoint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("endpoints.row.\(endpoint.name)")
            }
            .onDelete { offsets in
                for i in offsets { router.delete(router.endpoints[i].id) }
            }

            Menu {
                ForEach(EndpointPreset.addable(appleAvailable: router.appleAvailability.isAvailable)) { preset in
                    Button {
                        editing = EditTarget(endpoint: preset.make(), isNew: true)
                    } label: {
                        Label(preset.label, systemImage: preset.systemImage)
                    }
                    .accessibilityIdentifier("endpoints.preset.\(preset.rawValue)")
                }
            } label: {
                // Full-width hit area: without it only the label text opens the menu.
                Label("Add endpoint", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("endpoints.add")
        } header: {
            Text("Endpoints")
        } footer: {
            Text("Anthropic and OpenAI use your own API keys. Ollama, LM Studio and other OpenAI-compatible servers on your network work too; use your Mac's address instead of localhost.")
        }
    }

    private func endpointRow(_ e: LLMEndpoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.body)
                Text(e.model.isEmpty ? "No model selected" : e.model)
                    .font(.caption)
                    .foregroundStyle(e.model.isEmpty ? .orange : .secondary)
            }
            Spacer()
            if let issue = router.issue(for: e) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(issue.localizedDescription)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Ready")
            }
        }
        .contentShape(Rectangle())
    }

    private var routingSection: some View {
        Section {
            ForEach(AIPurpose.allCases) { purpose in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(purpose.label, selection: primaryBinding(purpose)) {
                        Text("Automatic (\(automaticName))").tag(UUID?.none)
                        ForEach(router.endpoints) { e in
                            Text(e.name).tag(UUID?.some(e.id))
                        }
                    }
                    .accessibilityIdentifier("endpoints.route.\(purpose.rawValue)")
                    Picker("If it fails", selection: fallbackBinding(purpose)) {
                        Text("No fallback").tag(UUID?.none)
                        ForEach(router.endpoints) { e in
                            Text(e.name).tag(UUID?.some(e.id))
                        }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("endpoints.fallback.\(purpose.rawValue)")
                }
            }
        } header: {
            Text("Routing")
        } footer: {
            Text("Choose which endpoint handles each kind of task. The fallback is tried when the first one is unreachable, overloaded or declines.")
        }
    }

    private var automaticName: String {
        (router.endpoints.first(where: { $0.kind != .appleOnDevice }) ?? router.endpoints.first)?.name ?? "none"
    }

    private func primaryBinding(_ purpose: AIPurpose) -> Binding<UUID?> {
        Binding(get: { router.explicitRoute(purpose) }, set: { router.setRoute(purpose, to: $0) })
    }

    private func fallbackBinding(_ purpose: AIPurpose) -> Binding<UUID?> {
        Binding(get: { router.explicitFallback(purpose) }, set: { router.setFallback(purpose, to: $0) })
    }

    private var usageSection: some View {
        Section {
            ForEach(router.endpoints) { e in
                let u = router.usage(for: e)
                LabeledContent(e.name) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(u.input.formatted()) in · \(u.output.formatted()) out")
                        if let cost = router.estimatedCost(for: e) {
                            Text(cost, format: .currency(code: "USD"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .accessibilityIdentifier("endpoints.usage.\(e.name)")
            }
            Button("Reset usage") { router.resetUsage() }
                .accessibilityIdentifier("endpoints.resetUsage")
        } header: {
            Text("Usage this month")
        } footer: {
            Text("Token counts as reported by each service. Costs are estimates from the prices set on each endpoint.")
        }
    }
}
