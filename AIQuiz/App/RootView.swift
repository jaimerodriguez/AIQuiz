import SwiftUI

struct RootView: View {
    var recoveredBackup: URL?
    @State private var showRecovery = false

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .onAppear { showRecovery = recoveredBackup != nil }
        .alert("Library could not be opened", isPresented: $showRecovery) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AIQuiz started a new, empty library. A copy of the old one was kept in the app's data (Backups › \(recoveredBackup?.lastPathComponent ?? "")) so it can be recovered.")
        }
    }
}
