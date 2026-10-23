import Foundation

/// Fill-in-the-blank cards (SPEC D-2): the prompt holds `{{blank}}` markers and the short
/// answer the missing texts joined by `|`.
public enum Cloze {
    public static let marker = "{{blank}}"

    /// The prompt's text around the blanks: n blanks give n + 1 segments.
    public static func segments(_ prompt: String) -> [String] {
        prompt.components(separatedBy: marker)
    }

    public static func blankCount(_ prompt: String) -> Int {
        max(0, segments(prompt).count - 1)
    }

    /// The expected text for each blank. A single answer fills every blank when there are
    /// more blanks than answers.
    public static func expected(_ shortAnswer: String?, blanks: Int) -> [String] {
        let parts = (shortAnswer ?? "").components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard blanks > 0 else { return parts.filter { !$0.isEmpty } }
        if parts.count >= blanks { return Array(parts.prefix(blanks)) }
        return parts + Array(repeating: parts.last ?? "", count: blanks - parts.count)
    }

    /// Case- and whitespace-insensitive comparison of every blank (F-17).
    public static func matches(_ given: [String], expected: [String]) -> Bool {
        guard given.count == expected.count else { return false }
        return zip(given, expected).allSatisfy { normalised($0) == normalised($1) }
    }

    /// The prompt with each blank replaced, for showing the answer.
    public static func filled(_ prompt: String, with answers: [String]) -> String {
        let parts = segments(prompt)
        var result = parts.first ?? ""
        for (index, part) in parts.dropFirst().enumerated() {
            result += "[" + (index < answers.count ? answers[index] : "…") + "]" + part
        }
        return result
    }

    static func normalised(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
