import SwiftUI
import UniformTypeIdentifiers
import AIQuizCore
import SwiftData

/// The home screen and every folder in it (SPEC F-1, F-4, F-63). Rows read only stored
/// fields, never a quiz's cards or sessions, so the list stays fast at the N-8 scale target.
/// `LibraryRulesTests` enforces it. Settings, Insights and the navigation destinations live
/// on the top level only; New folder and the + menu work at every level.
struct LibraryView: View {
    /// The folder shown; nil is the top level.
    var folder: FolderRecord? = nil
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Active quizzes, for the empty state and the tag chips. Reads stored attributes only.
    @Query(filter: #Predicate<QuizRecord> { !$0.isArchived }) private var activeQuizzes: [QuizRecord]
    @Query(filter: #Predicate<QuizRecord> { $0.isArchived }) private var archivedQuizzes: [QuizRecord]
    @Query private var allFolders: [FolderRecord]
    @State private var folderActions = FolderActions()

    @State private var searchText = ""
    @State private var importing = false
    @State private var importingAnki = false
    @Environment(AnkiImportRouter.self) private var ankiRouter
    @State private var importError: String?
    @State private var generateSource: GenerateQuizView.Source?
    @State private var batching = false
    @Environment(GenerationQueue.self) private var queue
    @Environment(ReviewRouter.self) private var reviewRouter
    @State private var actions = QuizActions()
    @State private var sourceStatus = SourceStatus()


    private var isTopLevel: Bool { folder == nil }

    private var isEmpty: Bool {
        if let folder {
            return !allFolders.contains { $0.parentID == folder.id } && !activeQuizzes.contains { $0.folderID == folder.id }
        }
        return activeQuizzes.isEmpty && archivedQuizzes.isEmpty && queue.jobs.isEmpty && allFolders.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty && searchText.isEmpty {
                emptyState
            } else {
                let list = LibraryList(
                    folderID: folder?.id,
                    sort: settings.librarySort,
                    sortSelection: Bindable(settings).librarySort,
                    search: searchText,
                    // iPad: search sits in the header row next to sort (CR-012).
                    inlineSearch: sizeClass == .regular ? $searchText : nil,
                    actions: actions,
                    folderActions: folderActions,
                    sourceStatus: sourceStatus
                )
                if sizeClass == .regular {
                    list
                } else {
                    // iPhone: the system search bar at the bottom.
                    list.searchable(text: $searchText, prompt: "Search names and #tags")
                }
            }
        }
        .navigationTitle(folder?.name ?? "AIQuiz")
        .toolbar {
            if isTopLevel {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("library.settings")
                }
                // F-7: the progress report.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        InsightsView()
                    } label: {
                        Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .accessibilityIdentifier("library.insights")
                }
            }
            // The app's main action: an accent circle without the toolbar's glass (CR-011).
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // F-63: a folder where you are.
                    Button {
                        folderActions.startCreating()
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("library.newFolder")
                    // F-3: every source opens the Generate screen with that source chosen.
                    Section("Generate with AI") {
                        addItem("From a topic", "sparkles", .topic, id: "library.generate")
                        addItem("From a web page", "globe", .url, id: "library.fromURL")
                        addItem("From a document", "doc.text", .document, id: "library.fromDocument")
                        addItem("From photos", "camera.viewfinder", .photo, id: "library.fromPhoto")
                        addItem("From pasted text", "doc.on.clipboard", .paste, id: "library.fromPaste")
                        Button {
                            batching = true
                        } label: {
                            Label("Batch from a list of links", systemImage: "list.bullet.rectangle")
                        }
                        .accessibilityIdentifier("library.batch")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("library.import")
                    Button {
                        importingAnki = true
                    } label: {
                        Label("Import Anki deck", systemImage: "rectangle.stack")
                    }
                    .accessibilityIdentifier("library.importAnki")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.gradient, in: Circle())
                        .accessibilityLabel("Add Quiz")
                }
                .accessibilityIdentifier("library.addButton")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: $generateSource) { source in
            NavigationStack {
                GenerateQuizView(initialSource: source, folderID: folder?.id)
            }
        }
        .sheet(isPresented: $batching) {
            NavigationStack { BatchFromListView(folderID: folder?.id) }
        }
        .modifier(TopLevelDestinations(isTopLevel: isTopLevel, reviewRouter: reviewRouter, ankiRouter: ankiRouter))
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                do {
                    try QuizImporter.importFiles(urls, into: context, folder: folder?.id)
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        // A second importer on its own view: two on one view conflict (only one presents).
        .background {
            Color.clear.fileImporter(isPresented: $importingAnki, allowedContentTypes: UTType.ankiPickerTypes) { result in
                switch result {
                case .success(let url): ankiRouter.open(url, securityScoped: true, folderID: folder?.id)
                case .failure(let error): importError = error.localizedDescription
                }
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
        .quizActions(actions)
        .folderActions(folderActions, in: folder?.id)
        .onAppear {
            actions.sourceStatus = sourceStatus
            actions.queue = queue
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isTopLevel {
            ContentUnavailableView(
                "No quizzes yet",
                systemImage: "rectangle.stack.badge.plus",
                description: Text("Import a JSON quiz or an Anki deck from Files, or generate one with AI.")
            )
        } else {
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("Use + to make a quiz or a folder here, or move quizzes in with Move to….")
            )
            .accessibilityIdentifier("library.emptyFolder")
        }
    }

    private func addItem(_ title: String, _ icon: String, _ source: GenerateQuizView.Source, id: String) -> some View {
        Button {
            generateSource = source
        } label: {
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier(id)
    }

}

/// What only the top-level library registers: quiz and folder pages, the Due today review
/// and the Anki import sheet. Folder screens are pushed onto the same stack and use these.
private struct TopLevelDestinations: ViewModifier {
    let isTopLevel: Bool
    let reviewRouter: ReviewRouter
    let ankiRouter: AnkiImportRouter

    func body(content: Content) -> some View {
        if isTopLevel {
            content
                .navigationDestination(for: QuizRecord.self) { quiz in
                    QuizDetailView(quiz: quiz)
                }
                .navigationDestination(for: FolderRecord.self) { folder in
                    LibraryView(folder: folder)
                }
                .navigationDestination(isPresented: Bindable(reviewRouter).showReview) {
                    ReviewSessionView()
                }
                .sheet(item: Bindable(ankiRouter).pending) { request in
                    AnkiImportView(request: request)
                }
        } else {
            content
        }
    }
}
