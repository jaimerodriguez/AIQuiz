import SwiftUI
import UniformTypeIdentifiers
import AIQuizCore
import SwiftData

/// The home screen (SPEC F-1, F-4). Rows read only stored fields, never a quiz's cards or
/// sessions, so the list stays fast at the N-8 scale target. `LibraryRulesTests` enforces it.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Active quizzes, for the empty state and the tag chips. Reads stored attributes only.
    @Query(filter: #Predicate<QuizRecord> { !$0.isArchived }) private var activeQuizzes: [QuizRecord]
    @Query(filter: #Predicate<QuizRecord> { $0.isArchived }) private var archivedQuizzes: [QuizRecord]

    @State private var searchText = ""
    @State private var selectedTag: String?
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

    /// Tag chips appear once the library is big enough to need them (F-1).
    static let tagChipThreshold = 10

    var body: some View {
        Group {
            if activeQuizzes.isEmpty && archivedQuizzes.isEmpty && queue.jobs.isEmpty {
                ContentUnavailableView(
                    "No quizzes yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Import a JSON quiz or an Anki deck from Files, or generate one with AI.")
                )
            } else {
                let list = LibraryList(
                    sort: settings.librarySort,
                    sortSelection: Bindable(settings).librarySort,
                    search: searchText,
                    // iPad: search sits in the header row next to sort (CR-012).
                    inlineSearch: sizeClass == .regular ? $searchText : nil,
                    tag: selectedTag,
                    tags: activeQuizzes.count > Self.tagChipThreshold ? allTags : [],
                    selectedTag: $selectedTag,
                    actions: actions,
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
            // F-7: the progress report.
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    InsightsView()
                } label: {
                    Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                }
                .accessibilityIdentifier("library.insights")
            }
            // The app's main action: an accent circle without the toolbar's glass (CR-011).
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                GenerateQuizView(initialSource: source)
            }
        }
        .sheet(isPresented: $batching) {
            NavigationStack { BatchFromListView() }
        }
        .navigationDestination(for: QuizRecord.self) { quiz in
            QuizDetailView(quiz: quiz)
        }
        .navigationDestination(isPresented: Bindable(reviewRouter).showReview) {
            ReviewSessionView()
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
        // A second importer on its own view: two on one view conflict (only one presents).
        .background {
            Color.clear.fileImporter(isPresented: $importingAnki, allowedContentTypes: UTType.ankiPickerTypes) { result in
                switch result {
                case .success(let url): ankiRouter.open(url, securityScoped: true)
                case .failure(let error): importError = error.localizedDescription
                }
            }
        }
        .sheet(item: Bindable(ankiRouter).pending) { request in
            AnkiImportView(request: request)
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
        .onAppear {
            actions.sourceStatus = sourceStatus
            actions.queue = queue
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
    @Binding var sortSelection: LibrarySort
    let inlineSearch: Binding<String>?
    private let searching: Bool
    let tags: [String]
    @Binding var selectedTag: String?
    let actions: QuizActions
    let sourceStatus: SourceStatus
    @State private var showArchived = false
    @State private var launchMilliseconds: Int?

    init(sort: LibrarySort, sortSelection: Binding<LibrarySort>, search: String, inlineSearch: Binding<String>?, tag: String?, tags: [String], selectedTag: Binding<String?>, actions: QuizActions, sourceStatus: SourceStatus) {
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
        _sortSelection = sortSelection
        self.inlineSearch = inlineSearch
        self.searching = !term.isEmpty
        _selectedTag = selectedTag
        self.actions = actions
        self.sourceStatus = sourceStatus
    }

    static func sortDescriptors(_ sort: LibrarySort) -> [SortDescriptor<QuizRecord>] {
        switch sort {
        case .recent:
            return [SortDescriptor(\.lastStudiedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        case .name:
            return [SortDescriptor(\.name, comparator: .localizedStandard)]
        case .mostDue:
            return [SortDescriptor(\.dueCount, order: .reverse), SortDescriptor(\.name, comparator: .localizedStandard)]
        case .newest:
            return [SortDescriptor(\.createdAt, order: .reverse)]
        }
    }

    var body: some View {
        List {
            DueTodayRow()
            GeneratingSection()
            if !tags.isEmpty {
                tagChips
            }
            Section {
                ForEach(quizzes) { quiz in
                    row(quiz)
                }
                if quizzes.isEmpty && (selectedTag != nil || searching) {
                    Text(selectedTag == nil ? "No quizzes match your search." : "No quizzes with this tag match.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("library.noMatches")
                }
            } header: {
                listHeader
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
            QuizRow(quiz: quiz, sourceMissing: sourceStatus.isMissing(quiz))
        }
        .task(id: quiz.sourceBookmark) { await sourceStatus.check(quiz) }
        .accessibilityIdentifier("library.row.\(quiz.id.uuidString)")
        .onAppear {
            if AppEnvironment.current.isUITest, launchMilliseconds == nil {
                LaunchMetric.markFirstRow()
                launchMilliseconds = LaunchMetric.firstRowMilliseconds
            }
        }
        .contextMenu { actions.menu(for: quiz, idPrefix: "library", sourceMissing: sourceStatus.isMissing(quiz)) }
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
            .tint(.gray)
        }
    }

    /// Count and sort, at the top of the list rather than in the toolbar, so the add button
    /// stands alone (CR-011).
    private var listHeader: some View {
        HStack(spacing: 16) {
            if let inlineSearch {
                InlineSearchField(text: inlineSearch)
                    .frame(maxWidth: 420)
            }
            Text(quizzes.count == 1 ? "1 quiz" : "\(quizzes.count) quizzes")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Sort by", selection: $sortSelection) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.label).tag(sort)
                            .accessibilityIdentifier("library.sort.\(sort.rawValue)")
                    }
                }
            } label: {
                Label(sortSelection.label, systemImage: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("library.sort")
        }
        .font(.subheadline)
        .textCase(nil)
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
    var sourceMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quiz.name).font(.headline)
                if sourceMissing {
                    Label("Source missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("library.sourceMissing")
                }
            }
            // Stats never wrap mid-word; on a narrow row the tags move to their own line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    stats
                    tags
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) { stats }
                    tags
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stats: some View {
        stat("\(quiz.cardCount) cards", icon: "rectangle.on.rectangle")
        if let best = quiz.bestScore {
            stat(percentText(best), icon: "star.fill")
                .foregroundStyle(.yellow)
        }
        if let avg = quiz.averageScore {
            stat("avg \(percentText(avg))", icon: "chart.bar")
        }
        if quiz.dueCount > 0 {
            stat("\(quiz.dueCount) due", icon: "calendar.badge.clock")
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("library.due")
        }
    }

    /// An icon and a value that never wrap.
    private func stat(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var tags: some View {
        if !quiz.tags.isEmpty {
            Text(quiz.tags.map { "#\($0)" }.joined(separator: " "))
                .lineLimit(1)
        }
    }

    private func percentText(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

/// The iPad library's search field, in the row above the list (CR-012).
private struct InlineSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search names and #tags", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityIdentifier("library.search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("library.search.clear")
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

/// *Due today* (SPEC F-2): one `fetchCount` over cards, hidden when nothing is due. Opens the
/// cross-quiz review (F-41).
private struct DueTodayRow: View {
    @Environment(\.modelContext) private var context
    @Environment(ReviewRouter.self) private var reviewRouter
    /// Changes whenever quiz counters change, so the count refreshes after sessions.
    @Query(filter: #Predicate<QuizRecord> { !$0.isArchived }) private var quizzes: [QuizRecord]

    var body: some View {
        let count = ScoreStore.dueCount(in: context)
        let _ = quizzes.count
        if count > 0 {
            Section {
                Button {
                    reviewRouter.showReview = true
                } label: {
                    HStack(spacing: 12) {
                        AccentIcon(systemName: "calendar.badge.clock", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Due today").font(.headline)
                            Text(count == 1 ? "1 card to review" : "\(count) cards to review")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.dueToday")
            }
        }
    }
}
