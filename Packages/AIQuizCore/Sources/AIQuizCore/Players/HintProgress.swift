import Foundation

/// Progressive hints for one card (F-24): each tap reveals the next hint; after the last
/// one, a tap hides them all.
public struct HintProgress: Sendable, Equatable {
    public private(set) var level = 0
    public let hints: [String]

    public init(hints: [String]) {
        self.hints = hints
    }

    public var isAvailable: Bool { !hints.isEmpty }
    public var shown: [String] { Array(hints.prefix(level)) }
    public var hasMore: Bool { level < hints.count }

    /// Label for the Hint button in this state.
    public var buttonLabel: String {
        if level == 0 { return "Hint" }
        return hasMore ? "Another hint" : "Hide hints"
    }

    /// Reveals the next hint, or hides them all after the last. Returns true when a hint was revealed.
    @discardableResult
    public mutating func advance() -> Bool {
        guard isAvailable else { return false }
        if hasMore {
            level += 1
            return true
        }
        level = 0
        return false
    }
}
