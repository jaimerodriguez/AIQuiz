import SwiftUI
import SwiftData
import AIQuizCore

/// Rename, Edit tags, Archive, Export JSON, Export to Anki and Delete for a quiz (SPEC F-4, F-10, F-62). Shared by
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
    var exportDocument: QuizFileDocument?
    var exportName = "Quiz"
    var deleting: QuizRecord?
    var exportError: String?
    /// The quiz whose source file is being re-linked (F-5).
    var relinking: QuizRecord?
    var relinkError: String?
    /// *Move to…* (F-63).
    var moving: MoveTarget?
    /// Told when a quiz was re-linked, so the library rechecks it.
    var sourceStatus: SourceStatus?
    /// Where *Regenerate from source* sends its job (F-4).
    var queue: GenerationQueue?

    @ViewBuilder
    func menu(for quiz: QuizRecord, idPrefix: String, includeDelete: Bool = true, sourceMissing: Bool = false) -> some View {
        if sourceMissing {
            Button {
                self.relinking = quiz
            } label: {
                Label("Re-link file", systemImage: "link")
            }
            .accessibilityIdentifier("\(idPrefix).relink")
        }
        if queue != nil, let job = Self.regenerationJob(for: quiz) {
            Button {
                self.queue?.enqueue(job)
            } label: {
                Label("Regenerate from source", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("\(idPrefix).regenerate")
        }
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
            self.moving = .quiz(quiz)
        } label: {
            Label("Move to…", systemImage: "folder")
        }
        .accessibilityIdentifier("\(idPrefix).move")
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
        Button {
            self.exportToAnki(quiz)
        } label: {
            Label("Export to Anki", systemImage: "rectangle.stack")
        }
        .disabled(quiz.cardCount == 0)
        .accessibilityIdentifier("\(idPrefix).exportAnki")
        if includeDelete {
            Button(role: .destructive) {
                self.confirmDelete(quiz)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("\(idPrefix).delete")
        }
    }

    /// F-4: a new job from the quiz's kept source; the new quiz arrives next to the old one.
    static func regenerationJob(for quiz: QuizRecord) -> GenerationJob? {
        let title = "Regenerate: \(quiz.name)"
        switch quiz.sourceKind {
        case .webPage?:
            guard let url = quiz.sourceURL else { return nil }
            return GenerationJob(title: title, source: .url(url), regenerating: quiz.id, folderID: quiz.folderID)
        case .markdownFile?, .pdfFile?:
            if let bookmark = quiz.sourceBookmark {
                let name = quiz.sourceTitle ?? "Document"
                return GenerationJob(title: title, source: .file(name: name, bookmark: bookmark, kind: quiz.sourceKind == .pdfFile ? .pdf : .markdown), regenerating: quiz.id, folderID: quiz.folderID)
            }
            return quiz.sourceText.map { GenerationJob(title: title, source: .text($0), regenerating: quiz.id, folderID: quiz.folderID) }
        case .pastedText?, .scannedPages?:
            return quiz.sourceText.map { GenerationJob(title: title, source: .text($0), regenerating: quiz.id, folderID: quiz.folderID) }
        case nil:
            return nil
        }
    }

    func toggleArchive(_ quiz: QuizRecord) {
        quiz.isArchived.toggle()
        save(quiz.modelContext, "archive")
    }

    func export(_ quiz: QuizRecord) {
        do {
            // The folder path travels with the quiz (F-63), for another app to rebuild the tree.
            var payload = quiz.payload
            if let context = quiz.modelContext { payload.folder = FolderStore.path(to: quiz.folderID, in: context) }
            exportDocument = QuizFileDocument(data: try QuizDecoder.encode(payload))
            exportName = QuizFileDocument.fileName(for: quiz.name)
            exporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// F-62: an `.apkg` with the quiz's cards and schedules (docs/anki-interchange.md §3).
    func exportToAnki(_ quiz: QuizRecord) {
        do {
            exportDocument = QuizFileDocument(data: try AnkiLibrary.package(for: quiz), contentType: .ankiPackage)
            exportName = QuizFileDocument.fileName(for: quiz.name)
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
            .sheet(item: $actions.moving) { target in
                MoveToFolderView(target: target)
            }
            .fileExporter(
                isPresented: $actions.exporting,
                document: actions.exportDocument,
                contentType: actions.exportDocument?.contentType ?? .json,
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
            .background {
                Color.clear.fileImporter(
                    isPresented: Binding(get: { actions.relinking != nil }, set: { if !$0 { actions.relinking = nil } }),
                    allowedContentTypes: actions.relinking.map(SourceLink.contentTypes(for:)) ?? [.json]
                ) { result in
                    guard let quiz = actions.relinking else { return }
                    actions.relinking = nil
                    do {
                        try SourceLink.relink(quiz, to: try result.get())
                        if let status = actions.sourceStatus {
                            Task { await status.check(quiz) }
                        }
                    } catch {
                        actions.relinkError = error.localizedDescription
                    }
                }
            }
            .alert("Re-link failed", isPresented: Binding(get: { actions.relinkError != nil }, set: { if !$0 { actions.relinkError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.relinkError ?? "")
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
                    .primaryActionStyle()
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
