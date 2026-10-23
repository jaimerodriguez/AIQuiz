import SwiftUI
import LLMKit

/// Hands a view the client for a purpose, or opens endpoint setup when there isn't one
/// (SPEC §8: the lazy setup sheet). Attach with `.aiSetupSheet(_:)`.
@MainActor
@Observable
final class AIGate {
    var setupIssue: String?
    var showingSetup = false

    func client(_ purpose: AIPurpose, from router: AIRouter) -> LLMClient? {
        if let issue = router.issue(for: purpose) {
            setupIssue = issue.localizedDescription
            showingSetup = true
            return nil
        }
        do {
            return try router.client(for: purpose)
        } catch {
            setupIssue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showingSetup = true
            return nil
        }
    }
}

extension View {
    func aiSetupSheet(_ gate: AIGate) -> some View {
        sheet(isPresented: Bindable(gate).showingSetup) {
            NavigationStack { EndpointsListView(setupIssue: gate.setupIssue, showsDoneButton: true) }
        }
    }
}

/// A friendly message for a failed AI call (SPEC §7.3).
func aiMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
