import SwiftUI
import AIQuizCore
import SwiftData

/// The home screen (SPEC F-1, F-4). Rows read only stored fields, never a quiz's cards or
/// sessions, so the list stays fast at the N-8 scale target. `LibraryRulesTests` enforces it.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    /// Active quizzes, for the empty state and the tag chips. Reads stored attributes only.
    @Query(filter: #Predicate<QuizRecord> { !$0.isArchived }) private var activeQuizzes: [QuizRecord]
    @Query(filter: #Predicate<QuizRecord> { $0.isArchived }) private var archivedQuizzes: [QuizRecord]

    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var importing = false
    @State private var importError: String?
    @State private var generating = false
    @State private var actions = QuizActions()

    /// Tag chips appear once the library is big enough to need them (F-1).
    static let tagChipThreshold = 10

    var body: some View {
        Group {
            if activeQuizzes.isEmpty && archivedQuizzes.isEmpty {
                ContentUnavailableView(
                    "No quizzes yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Import a JSON quiz from Files or generate one with AI.")
                )
            } else {
                LibraryList(
                    sort: settings.librarySort,
                    search: searchText,
                    tag: selectedTag,
                    tags: activeQuizzes.count > Self.tagChipThreshold ? allTags : [],
                    selectedTag: $selectedTag,
                    actions: actions
                )
                .searchable(text: $searchText, prompt: "Search names and #tags")
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
                .accessibilityIdentifier("library.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: Bindable(settings).librarySort) {
                        ForEach(LibrarySort.allCases) { sort in
                            Text(sort.label).tag(sort)
                                .accessibilityIdentifier("library.sort.\(sort.rawValue)")
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("library.sort")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        generating = true
                    } label: {
                        Label("Generate with AI", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("library.generate")
                    Button {
                        importing = true
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("library.import")
                } label: {
                    Label("Add Quiz", systemImage: "plus")
                }
                .accessibilityIdentifier("library.addButton")
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
                do {
                    try QuizImporter.importFiles(urls, into: context)
                } catch {
                    importError = error.localizedDescription
                }
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
        .quizActions(actions)
    }

    /// Every tag on an active quiz, most used first.
    private var allTags: [String] {
        var counts: [String: Int] = [:]
        for quiz in activeQuizzes {
            for tag in quiz.tags { counts[tag.lowercased(), default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// The list itself, re-queried whenever the sort, search or tag changes.
private struct LibraryList: View {
    @Query private var quizzes: [QuizRecord]
    @Query private var archived: [QuizRecord]
    let tags: [String]
    @Binding var selectedTag: String?
    let actions: QuizActions
    @State private var showArchived = false
    @State private var launchMilliseconds: Int?

    init(sort: LibrarySort, search: String, tag: String?, tags: [String], selectedTag: Binding<String?>, actions: QuizActions) {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let needle = tag.map(TagsSearch.needle(forTag:)) ?? ""
        _quizzes = Query(
            filter: #Predicate<QuizRecord> { quiz in
                !quiz.isArchived
                    && (term.isEmpty || quiz.tagsSearch.contains(term))
                    && (needle.isEmpty || quiz.tagsSearch.contains(needle))
            },
            sort: Self.sortDescriptors(sort)
        )
        _archived = Query(
            filter: #Predicate<QuizRecord> { quiz in
                quiz.isArchived && (term.isEmpty || quiz.tagsSearch.contains(term))
            },
            sort: [SortDescriptor(\QuizRecord.name, comparator: .localizedStandard)]
        )
        self.tags = tags
        _selectedTag = selectedTag
        self.actions = actions
    }

    static func sortDescriptors(_ sort: LibrarySort) -> [SortDescriptor<QuizRecord>] {
        switch sort {
        case .recent:
            return [SortDescriptor(\.lastStudiedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        case .name:
            return [SortDescriptor(\.name, comparator: .localizedStandard)]
        case .newest:
            return [SortDescriptor(\.createdAt, order: .reverse)]
        }
    }

    var body: some View {
        List {
            if !tags.isEmpty {
                tagChips
            }
            ForEach(quizzes) { quiz in
                row(quiz)
            }
            if quizzes.isEmpty {
                Text(selectedTag == nil ? "No quizzes match your search." : "No quizzes with this tag match.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.noMatches")
            }
            if !archived.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showArchived) {
                        ForEach(archived) { quiz in
                            row(quiz)
                        }
                    } label: {
                        Label("Archived (\(archived.count))", systemImage: "archivebox")
                            .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("library.archived")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if AppEnvironment.current.isUITest, let ms = launchMilliseconds {
                Text(verbatim: "\(ms)")
                    .font(.system(size: 4))
                    .opacity(0.02)
                    .accessibilityIdentifier("library.launchMetric")
            }
        }
    }

    private func row(_ quiz: QuizRecord) -> some View {
        NavigationLink(value: quiz) {
            QuizRow(quiz: quiz)
        }
        .accessibilityIdentifier("library.row.\(quiz.id.uuidString)")
        .onAppear {
            if AppEnvironment.current.isUITest, launchMilliseconds == nil {
                LaunchMetric.markFirstRow()
                launchMilliseconds = LaunchMetric.firstRowMilliseconds
            }
        }
        .contextMenu { actions.menu(for: quiz, idPrefix: "library") }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                actions.confirmDelete(quiz)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("library.swipeDelete")
            Button {
                actions.toggleArchive(quiz)
            } label: {
                Label(quiz.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    let selected = selectedTag == tag
                    Button {
                        selectedTag = selected ? nil : tag
                    } label: {
                        Text("#\(tag)")
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.tag.\(tag)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// One library row: stored fields only (SPEC D-11, N-8).
private struct QuizRow: View {
    let quiz: QuizRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quiz.name).font(.headline)
            HStack(spacing: 12) {
                Label("\(quiz.cardCount) cards", systemImage: "rectangle.on.rectangle")
                if let best = quiz.bestScore {
                    Label(percentText(best), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
                if let avg = quiz.averageScore {
                    Label("avg \(percentText(avg))", systemImage: "chart.bar")
                        .foregroundStyle(.secondary)
                }
                if !quiz.tags.isEmpty {
                    Text(quiz.tags.map { "#\($0)" }.joined(separator: " "))
                        .lineLimit(1)
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
