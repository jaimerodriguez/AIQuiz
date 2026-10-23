import SwiftUI
import SwiftData
import AIQuizCore

/// Rename, Edit tags, Archive, Export JSON and Delete for a quiz (SPEC F-4, F-10). Shared by
/// the library's context menu and the quiz screen's toolbar; `.quizActions(_:)` attaches
/// the sheets and alerts.
@Observable
@MainActor
final class QuizActions {
    struct EditRequest: Identifiable {
        enum Focus { case name, tags }
        let quiz: QuizRecord
        let focus: Focus
        var id: UUID { quiz.id }
    }

    var editing: EditRequest?
    var exporting = false
    var exportDocument: QuizJSONDocument?
    var exportName = "Quiz"
    var deleting: QuizRecord?
    var exportError: String?

    @ViewBuilder
    func menu(for quiz: QuizRecord, idPrefix: String, includeDelete: Bool = true) -> some View {
        Button {
            self.editing = EditRequest(quiz: quiz, focus: .name)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .accessibilityIdentifier("\(idPrefix).rename")
        Button {
            self.editing = EditRequest(quiz: quiz, focus: .tags)
        } label: {
            Label("Edit tags", systemImage: "tag")
        }
        .accessibilityIdentifier("\(idPrefix).editTags")
        Button {
            self.toggleArchive(quiz)
        } label: {
            Label(quiz.isArchived ? "Unarchive" : "Archive", systemImage: quiz.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
        .accessibilityIdentifier("\(idPrefix).archive")
        Button {
            self.export(quiz)
        } label: {
            Label("Export JSON", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("\(idPrefix).export")
        if includeDelete {
            Button(role: .destructive) {
                self.confirmDelete(quiz)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("\(idPrefix).delete")
        }
    }

    func toggleArchive(_ quiz: QuizRecord) {
        quiz.isArchived.toggle()
        save(quiz.modelContext, "archive")
    }

    func export(_ quiz: QuizRecord) {
        do {
            exportDocument = QuizJSONDocument(data: try QuizDecoder.encode(quiz.payload))
            exportName = QuizJSONDocument.fileName(for: quiz.name)
            exporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    func confirmDelete(_ quiz: QuizRecord) {
        deleting = quiz
    }

    func delete(_ quiz: QuizRecord) {
        let context = quiz.modelContext
        context?.delete(quiz)
        save(context, "delete")
        deleting = nil
    }

    private func save(_ context: ModelContext?, _ what: String) {
        do {
            try context?.save()
        } catch {
            Log.data.error("Quiz \(what) save failed: \(String(describing: error))")
        }
    }
}

extension View {
    func quizActions(_ actions: QuizActions) -> some View {
        modifier(QuizActionsModifier(actions: actions))
    }
}

private struct QuizActionsModifier: ViewModifier {
    @Bindable var actions: QuizActions

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.editing) { request in
                NavigationStack {
                    QuizDetailsEditor(quiz: request.quiz, focus: request.focus)
                }
            }
            .fileExporter(
                isPresented: $actions.exporting,
                document: actions.exportDocument,
                contentType: .json,
                defaultFilename: actions.exportName
            ) { result in
                if case .failure(let error) = result {
                    actions.exportError = error.localizedDescription
                }
            }
            .alert(
                "Delete “\(actions.deleting?.name ?? "")”?",
                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                presenting: actions.deleting
            ) { quiz in
                Button("Delete", role: .destructive) { actions.delete(quiz) }
                    .accessibilityIdentifier("quiz.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { quiz in
                Text("Its \(quiz.cardCount) cards and study history are deleted too. This can't be undone.")
            }
            .alert("Export failed", isPresented: Binding(get: { actions.exportError != nil }, set: { if !$0 { actions.exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.exportError ?? "")
            }
    }
}

/// Name, description and tags of a quiz (F-4 Rename and Edit tags).
struct QuizDetailsEditor: View {
    let quiz: QuizRecord
    let focus: QuizActions.EditRequest.Focus
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var tagsText = ""
    @FocusState private var focused: QuizActions.EditRequest.Focus?

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .focused($focused, equals: .name)
                    .accessibilityIdentifier("quizEdit.name")
            }
            Section {
                TextField("Tags", text: $tagsText, prompt: Text("history, rome"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .tags)
                    .accessibilityIdentifier("quizEdit.tags")
            } header: {
                Text("Tags")
            } footer: {
                Text("Separate tags with commas or spaces. Search finds a tag when you type #tag.")
            }
            Section("Description") {
                TextField("Optional", text: $descriptionText, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("quizEdit.description")
            }
        }
        .navigationTitle(focus == .tags ? "Edit tags" : "Rename quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("quizEdit.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quizEdit.save")
            }
        }
        .onAppear {
            name = quiz.name
            descriptionText = quiz.descriptionText ?? ""
            tagsText = quiz.tags.joined(separator: ", ")
            focused = focus
        }
    }

    private func save() {
        quiz.rename(to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        quiz.setTags(TagsSearch.parse(tagsText))
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        quiz.descriptionText = description.isEmpty ? nil : description
        do {
            try quiz.modelContext?.save()
        } catch {
            Log.data.error("Quiz edit save failed: \(String(describing: error))")
        }
        dismiss()
    }
}
