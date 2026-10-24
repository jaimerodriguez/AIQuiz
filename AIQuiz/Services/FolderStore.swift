import Foundation
import SwiftData
import AIQuizCore

/// The library's folders in the store (SPEC F-63, ADR-022): the only code that creates,
/// renames, moves or deletes folders, or moves quizzes between them. Tree logic lives in
/// `AIQuizCore.FolderTree`; counts read stored counters only (N-8).
@MainActor
enum FolderStore {
    enum Failure: LocalizedError, Equatable {
        case emptyName
        case wouldContainItself

        var errorDescription: String? {
            switch self {
            case .emptyName: return "A folder needs a name."
            case .wouldContainItself: return "A folder can't go inside itself."
            }
        }
    }

    /// What's inside a folder, at any depth.
    struct Contents: Equatable {
        var folders: Int
        var quizzes: Int
    }

    static func nodes(in context: ModelContext) -> [FolderNode] {
        ((try? context.fetch(FetchDescriptor<FolderRecord>())) ?? []).map { FolderNode(id: $0.id, name: $0.name, parentID: $0.parentID) }
    }

    static func folder(_ id: UUID?, in context: ModelContext) -> FolderRecord? {
        guard let id else { return nil }
        return try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// The folder names from the top level down to `id`, inclusive.
    static func path(to id: UUID?, in context: ModelContext) -> [String] {
        FolderTree.path(to: id, in: nodes(in: context)).map(\.name)
    }

    @discardableResult
    static func create(named raw: String, in parent: UUID?, context: ModelContext) throws -> FolderRecord {
        guard let name = FolderTree.cleanName(raw) else { throw Failure.emptyName }
        let siblings = FolderTree.children(of: parent, in: nodes(in: context)).map(\.name)
        let folder = FolderRecord(name: FolderTree.uniqueName(name, among: siblings), parentID: parent)
        context.insert(folder)
        try context.save()
        return folder
    }

    static func rename(_ folder: FolderRecord, to raw: String, context: ModelContext) throws {
        guard let name = FolderTree.cleanName(raw) else { throw Failure.emptyName }
        guard name != folder.name else { return }
        let siblings = FolderTree.children(of: folder.parentID, in: nodes(in: context)).filter { $0.id != folder.id }.map(\.name)
        folder.name = FolderTree.uniqueName(name, among: siblings)
        try context.save()
    }

    static func move(_ folder: FolderRecord, to parent: UUID?, context: ModelContext) throws {
        guard FolderTree.canMove(folder.id, into: parent, in: nodes(in: context)) else { throw Failure.wouldContainItself }
        guard folder.parentID != parent else { return }
        let siblings = FolderTree.children(of: parent, in: nodes(in: context)).map(\.name)
        folder.name = FolderTree.uniqueName(folder.name, among: siblings)
        folder.parentID = parent
        try context.save()
    }

    static func move(_ quiz: QuizRecord, to folder: UUID?, context: ModelContext) throws {
        quiz.folderID = folder
        try context.save()
    }

    /// The folder and every folder inside it.
    static func subtree(_ id: UUID, in context: ModelContext) -> [UUID] {
        [id] + Array(FolderTree.descendants(of: id, in: nodes(in: context)))
    }

    /// Quizzes in a set of folders (archived too). One indexed query per folder: SwiftData
    /// can't turn "an optional id is in this set" into SQL, and a folder tree is small.
    static func quizzes(inFolders ids: [UUID], context: ModelContext) -> [QuizRecord] {
        ids.flatMap { id in
            (try? context.fetch(FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.folderID == id }))) ?? []
        }
    }

    static func contents(of folder: FolderRecord, context: ModelContext) -> Contents {
        let ids = subtree(folder.id, in: context)
        return Contents(folders: ids.count - 1, quizzes: quizzes(inFolders: ids, context: context).count)
    }

    /// For a folder row: active quizzes inside, at any depth, and their due cards, from the
    /// stored counters (D-11).
    static func summary(of folder: FolderRecord, context: ModelContext) -> (quizzes: Int, due: Int) {
        let active = quizzes(inFolders: subtree(folder.id, in: context), context: context).filter { !$0.isArchived }
        return (active.count, active.reduce(0) { $0 + $1.dueCount })
    }

    /// Deletes the folder, every folder inside it, and every quiz in them with their cards
    /// and history (CR-022: the owner chose delete-with-contents, after a confirmation).
    static func delete(_ folder: FolderRecord, context: ModelContext) throws {
        let ids = subtree(folder.id, in: context)
        for quiz in quizzes(inFolders: ids, context: context) { context.delete(quiz) }
        let folders = (try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for record in folders { context.delete(record) }
        try context.save()
    }

    /// The folder at `names` under `parent`, creating any that are missing; nil for an empty
    /// path. Used by imports that carry a folder path (JSON, Anki deck paths).
    static func folderID(forPath names: [String], under parent: UUID?, context: ModelContext) throws -> UUID? {
        var current = parent
        for raw in names {
            guard let name = FolderTree.cleanName(raw) else { continue }
            let existing = FolderTree.children(of: current, in: nodes(in: context)).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            current = try existing?.id ?? create(named: name, in: current, context: context).id
        }
        return current
    }

    /// Whether the folder still exists.
    static func exists(_ id: UUID?, in context: ModelContext) -> Bool {
        guard let id else { return false }
        return (try? context.fetchCount(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id }))) ?? 0 > 0
    }

    /// Moves any quiz whose folder no longer exists back to the top level, so nothing is ever
    /// hidden by a stale id (ADR-022). Run at launch; returns how many were moved.
    @discardableResult
    static func repairMissingFolders(in context: ModelContext) -> Int {
        let existing = Set(nodes(in: context).map(\.id))
        let filed = (try? context.fetch(FetchDescriptor<QuizRecord>(predicate: #Predicate { $0.folderID != nil }))) ?? []
        let stray = filed.filter { !existing.contains($0.folderID!) }
        guard !stray.isEmpty else { return 0 }
        for quiz in stray { quiz.folderID = nil }
        try? context.save()
        Log.data.info("Moved \(stray.count) quizzes with a missing folder to the top level")
        return stray.count
    }
}
