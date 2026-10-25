import Foundation

/// A folder as the tree logic sees it (SPEC F-63): an id, a name and a parent; nil is the
/// top level. The app's `FolderRecord` maps to this one to one.
public struct FolderNode: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID, name: String, parentID: UUID?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

/// Paths, descendants, move checks and names for the folder tree (ADR-022). Pure, so it is
/// tested with `swift test`; the app's `FolderStore` applies the results to the store.
public enum FolderTree {
    /// The folders from the top level down to `id`, inclusive. Empty for the top level or an
    /// unknown id; a broken loop in stored data stops instead of spinning.
    public static func path(to id: UUID?, in folders: [FolderNode]) -> [FolderNode] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var path: [FolderNode] = []
        var seen = Set<UUID>()
        var current = id
        while let next = current, let node = byID[next], seen.insert(next).inserted {
            path.insert(node, at: 0)
            current = node.parentID
        }
        return path
    }

    /// Every folder inside `id`, at any depth (not `id` itself).
    public static func descendants(of id: UUID, in folders: [FolderNode]) -> Set<UUID> {
        let children = Dictionary(grouping: folders.filter { $0.parentID != nil }, by: { $0.parentID! })
        var found = Set<UUID>()
        var queue = [id]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where child.id != id && found.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return found
    }

    /// Whether `id` can move into `target` (nil is the top level): never into itself or
    /// anything inside it.
    public static func canMove(_ id: UUID, into target: UUID?, in folders: [FolderNode]) -> Bool {
        guard let target else { return true }
        return target != id && !descendants(of: id, in: folders).contains(target)
    }

    /// The folders directly inside `parent`, by name as Files sorts them.
    public static func children(of parent: UUID?, in folders: [FolderNode]) -> [FolderNode] {
        folders.filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every folder with its depth, top level first and each folder followed by its contents,
    /// for a "Move to…" list. `excluding` and its contents are left out.
    public static func outline(_ folders: [FolderNode], excluding: UUID? = nil) -> [(folder: FolderNode, depth: Int)] {
        let hidden = excluding.map { descendants(of: $0, in: folders).union([$0]) } ?? []
        var result: [(FolderNode, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for child in children(of: parent, in: folders) where !hidden.contains(child.id) {
                result.append((child, depth))
                walk(child.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    /// A trimmed name, or nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(120))
    }

    /// `name`, or `name 2`, `name 3`… when a sibling already has it (case-insensitive).
    public static func uniqueName(_ name: String, among siblings: [String]) -> String {
        let taken = Set(siblings.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }
}
