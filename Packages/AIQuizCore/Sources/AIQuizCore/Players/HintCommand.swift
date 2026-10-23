import Foundation

/// The spoken "hint" command (SPEC F-12).
public enum HintCommand {
    /// The words that ask for a hint.
    public static let words: Set<String> = ["hint", "hints"]

    /// Whether a (partial) transcript contains the command as a word, in any case.
    public static func matches(_ transcript: String) -> Bool {
        transcript
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { words.contains(String($0)) }
    }
}
