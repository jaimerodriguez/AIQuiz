import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \QuizRecord.importedAt, order: .reverse) private var quizzes: [QuizRecord]
    @State private var importing = false
    @State private var importError: String?
    @State private var generating = false

    var body: some View {
        Group {
            if quizzes.isEmpty {
                ContentUnavailableView(
                    "No quizzes yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Import a JSON quiz from Files or generate one with AI.")
                )
            } else {
                List {
                    ForEach(quizzes) { quiz in
                        NavigationLink(value: quiz) {
                            QuizRow(quiz: quiz)
                        }
                    }
                    .onDelete(perform: deleteQuizzes)
                }
            }
        }
        .navigationTitle("AIQuiz")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        generating = true
                    } label: {
                        Label("Generate with AI", systemImage: "sparkles")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Add Quiz", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $generating) {
            NavigationStack {
                GenerateQuizView()
            }
        }
        .navigationDestination(for: QuizRecord.self) { quiz in
            QuizDetailView(quiz: quiz)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importFiles(_ urls: [URL]) async {
        do {
            try await FileImportService.shared.importJSONFiles(urls, into: context)
        } catch {
            await MainActor.run { importError = error.localizedDescription }
        }
    }

    private func deleteQuizzes(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(quizzes[idx])
        }
        try? context.save()
    }
}

private struct QuizRow: View {
    let quiz: QuizRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quiz.name).font(.headline)
            HStack(spacing: 12) {
                Label("\(quiz.cards.count) cards", systemImage: "rectangle.on.rectangle")
                if let best = quiz.bestScore {
                    Label(percentText(best), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
                if let avg = quiz.averageScore {
                    Label("avg \(percentText(avg))", systemImage: "chart.bar")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func percentText(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}
