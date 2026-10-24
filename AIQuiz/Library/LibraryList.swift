import SwiftUI
import SwiftData
import AIQuizCore

/// The list for one place in the library (F-63): its folders, then its quizzes. Re-queried
/// whenever the folder, sort or search changes. A search covers the whole library.
struct LibraryList: View {
    @Query private var quizzes: [QuizRecord]
    @Query private var archived: [QuizRecord]
    /// Every folder: there are few, and the paths of search results need them all.
    @Query(sort: [SortDescriptor(\FolderRecord.name, comparator: .localizedStandard)]) private var folders: [FolderRecord]
    @Binding var sortSelection: LibrarySort
    let inlineSearch: Binding<String>?
    private let searching: Bool
    /// The folder shown; nil is the top level.
    let folderID: UUID?
    let actions: QuizActions
    let folderActions: FolderActions
    let sourceStatus: SourceStatus
    @State private var showArchived = false
    @State private var launchMilliseconds: Int?

    /// Search covers names and tags: a quiz's search text is its name plus "#tag" for each
    /// tag, so "#anki" finds quizzes tagged anki (F-1; the chip row was removed, CR-021).
    init(folderID: UUID?, sort: LibrarySort, sortSelection: Binding<LibrarySort>, search: String, inlineSearch: Binding<String>?,
         actions: QuizActions, folderActions: FolderActions, sourceStatus: SourceStatus) {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filter: Predicate<QuizRecord>
        if !term.isEmpty {
            filter = #Predicate<QuizRecord> { quiz in !quiz.isArchived && quiz.tagsSearch.contains(term) }
        } else if let folderID {
            filter = #Predicate<QuizRecord> { quiz in !quiz.isArchived && quiz.folderID == folderID }
        } else {
            filter = #Predicate<QuizRecord> { quiz in !quiz.isArchived && quiz.folderID == nil }
        }
        _quizzes = Query(filter: filter, sort: Self.sortDescriptors(sort))
        self.folderID = folderID
        self.folderActions = folderActions
        _archived = Query(
            filter: #Predicate<QuizRecord> { quiz in
                quiz.isArchived && (term.isEmpty || quiz.tagsSearch.contains(term))
            },
            sort: [SortDescriptor(\QuizRecord.name, comparator: .localizedStandard)]
        )
        _sortSelection = sortSelection
        self.inlineSearch = inlineSearch
        self.searching = !term.isEmpty
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

    private var isTopLevel: Bool { folderID == nil }

    /// The folders directly in this one; none while searching.
    private var subfolders: [FolderRecord] {
        searching ? [] : folders.filter { $0.parentID == folderID }
    }

    /// "Languages › Spanish" for each folder, shown under search results.
    private var paths: [UUID: String] {
        let nodes = folders.map { FolderNode(id: $0.id, name: $0.name, parentID: $0.parentID) }
        return Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, FolderTree.path(to: $0.id, in: nodes).map(\.name).joined(separator: " › ")) })
    }

    var body: some View {
        let paths = searching ? self.paths : [:]
        List {
            if isTopLevel {
                DueTodayRow()
                GeneratingSection()
            }
            if !subfolders.isEmpty {
                Section {
                    ForEach(subfolders) { folder in
                        FolderRow(folder: folder, actions: folderActions)
                    }
                }
            }
            Section {
                ForEach(quizzes) { quiz in
                    row(quiz, path: quiz.folderID.flatMap { paths[$0] })
                }
                if quizzes.isEmpty && searching {
                    Text("No quizzes match your search.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("library.noMatches")
                }
            } header: {
                listHeader
            }
            // Archive stays separate from folders: every archived quiz, listed at the top level.
            if isTopLevel && !archived.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showArchived) {
                        ForEach(archived) { quiz in
                            row(quiz, path: nil)
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

    private func row(_ quiz: QuizRecord, path: String?) -> some View {
        NavigationLink(value: quiz) {
            QuizRow(quiz: quiz, sourceMissing: sourceStatus.isMissing(quiz), folderPath: path)
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
}

/// One library row: stored fields only (SPEC D-11, N-8).
private struct QuizRow: View {
    let quiz: QuizRecord
    var sourceMissing = false
    /// The folder it's in, shown with search results (F-63).
    var folderPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let folderPath {
                Label(folderPath, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("library.row.path")
            }
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
