import SwiftUI
import SwiftData
import AIQuizCore

/// What *Move to…* moves (F-63).
enum MoveTarget: Identifiable {
    case quiz(QuizRecord)
    case folder(FolderRecord)

    var id: UUID {
        switch self {
        case .quiz(let quiz): return quiz.id
        case .folder(let folder): return folder.id
        }
    }

    var name: String {
        switch self {
        case .quiz(let quiz): return quiz.name
        case .folder(let folder): return folder.name
        }
    }

    /// Where it is now (nil: the top level).
    var location: UUID? {
        switch self {
        case .quiz(let quiz): return quiz.folderID
        case .folder(let folder): return folder.parentID
        }
    }
}

/// New folder, rename, move and delete for folders (F-63). Shared by the library screen at
/// every level; `.folderActions(_:in:)` attaches the prompts and the move sheet.
@Observable
@MainActor
final class FolderActions {
    var creating = false
    var renaming: FolderRecord?
    var name = ""
    var moving: MoveTarget?
    var deleting: FolderRecord?
    var error: String?

    func startCreating() {
        name = ""
        creating = true
    }

    func startRenaming(_ folder: FolderRecord) {
        name = folder.name
        renaming = folder
    }

    @ViewBuilder
    func menu(for folder: FolderRecord) -> some View {
        Button {
            self.startRenaming(folder)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .accessibilityIdentifier("library.folder.rename")
        Button {
            self.moving = .folder(folder)
        } label: {
            Label("Move to…", systemImage: "folder")
        }
        .accessibilityIdentifier("library.folder.move")
        Button(role: .destructive) {
            self.deleting = folder
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier("library.folder.delete")
    }
}

extension View {
    /// The New folder and Rename prompts, the delete confirmation and the move sheet.
    /// `parent` is the folder new folders go into (nil: the top level).
    func folderActions(_ actions: FolderActions, in parent: UUID?) -> some View {
        modifier(FolderActionsModifier(actions: actions, parent: parent))
    }
}

private struct FolderActionsModifier: ViewModifier {
    @Bindable var actions: FolderActions
    let parent: UUID?
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .alert("New folder", isPresented: $actions.creating) {
                TextField("Name", text: $actions.name)
                    .accessibilityIdentifier("folder.name")
                Button("Create") { run { _ = try FolderStore.create(named: actions.name, in: parent, context: context) } }
                    .accessibilityIdentifier("folder.create")
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename folder", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })) {
                TextField("Name", text: $actions.name)
                    .accessibilityIdentifier("folder.name")
                Button("Rename") {
                    if let folder = actions.renaming { run { try FolderStore.rename(folder, to: actions.name, context: context) } }
                }
                .accessibilityIdentifier("folder.saveName")
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Folder and Contents", role: .destructive) {
                    if let folder = actions.deleting { run { try FolderStore.delete(folder, context: context) } }
                }
                .accessibilityIdentifier("library.folder.confirmDelete")
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $actions.moving) { target in
                MoveToFolderView(target: target)
            }
            .alert("Couldn't do that", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.error ?? "")
            }
    }

    private var deleteTitle: String {
        "Delete “\(actions.deleting?.name ?? "")”?"
    }

    /// CR-022: deleting a folder deletes its contents, so say exactly how much.
    private var deleteMessage: String {
        guard let folder = actions.deleting else { return "" }
        let contents = FolderStore.contents(of: folder, context: context)
        var parts: [String] = []
        if contents.folders > 0 { parts.append(contents.folders == 1 ? "1 folder" : "\(contents.folders) folders") }
        if contents.quizzes > 0 { parts.append(contents.quizzes == 1 ? "1 quiz" : "\(contents.quizzes) quizzes") }
        guard !parts.isEmpty else { return "The folder is empty." }
        return "This also deletes the \(parts.joined(separator: " and ")) inside it, with their cards and history. This can't be undone."
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            actions.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A folder in the library: its name, and how many quizzes and due cards are inside at any
/// depth, read from stored counters (N-8).
struct FolderRow: View {
    let folder: FolderRecord
    let actions: FolderActions
    @Environment(\.modelContext) private var context

    var body: some View {
        let summary = FolderStore.summary(of: folder, context: context)
        NavigationLink(value: folder) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.headline)
                    HStack(spacing: 12) {
                        Text(summary.quizzes == 1 ? "1 quiz" : "\(summary.quizzes) quizzes")
                        if summary.due > 0 {
                            Label("\(summary.due) due", systemImage: "calendar.badge.clock")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("library.folder.\(folder.name)")
        .contextMenu { actions.menu(for: folder) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                actions.deleting = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// *Move to…* for a quiz or a folder: the top level and every folder, indented, with the
/// current place marked. A folder can't be moved into itself or anything inside it.
struct MoveToFolderView: View {
    let target: MoveTarget
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        let nodes = FolderStore.nodes(in: context)
        let excluded: UUID? = if case .folder(let folder) = target { folder.id } else { nil }
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.orange)
                }
                Section {
                    destination(nil, name: "Top level", icon: "tray.full", depth: 0)
                    ForEach(FolderTree.outline(nodes, excluding: excluded), id: \.folder.id) { item in
                        destination(item.folder.id, name: item.folder.name, icon: "folder", depth: item.depth)
                    }
                } footer: {
                    if excluded != nil { Text("A folder can't go inside itself.") }
                }
            }
            .navigationTitle("Move “\(target.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("move.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ id: UUID?, name: String, icon: String, depth: Int) -> some View {
        let current = id == target.location
        return Button {
            move(to: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                Text(name)
                    .foregroundStyle(current ? .secondary : .primary)
                Spacer()
                if current {
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
        }
        .disabled(current)
        .accessibilityIdentifier("move.to.\(name)")
    }

    private func move(to id: UUID?) {
        do {
            switch target {
            case .quiz(let quiz): try FolderStore.move(quiz, to: id, context: context)
            case .folder(let folder): try FolderStore.move(folder, to: id, context: context)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
