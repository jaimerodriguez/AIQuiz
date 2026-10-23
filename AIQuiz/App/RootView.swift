import SwiftUI

struct RootView: View {
    var recoveredBackup: URL?
    @Environment(AppSettings.self) private var settings
    @State private var showRecovery = false
    @State private var showOnboarding = false
    @State private var showEndpoints = false

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .onAppear {
            showRecovery = recoveredBackup != nil
            showOnboarding = AppEnvironment.current.allowsOnboarding && !settings.onboardingDone
        }
        .alert("Library could not be opened", isPresented: $showRecovery) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AIQuiz started a new, empty library. A copy of the old one was kept in the app's data (Backups › \(recoveredBackup?.lastPathComponent ?? "")) so it can be recovered.")
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { addEndpoint in
                settings.onboardingDone = true
                showOnboarding = false
                if addEndpoint { showEndpoints = true }
            }
        }
        .sheet(isPresented: $showEndpoints) {
            NavigationStack {
                EndpointsListView(showsDoneButton: true)
            }
        }
    }
}
