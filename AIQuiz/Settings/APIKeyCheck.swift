import Foundation
import LLMKit

/// Catches the usual copy-paste mistakes in API keys (CR-005): surrounding whitespace and
/// quotes are removed; inner whitespace and the wrong provider prefix produce a warning.
enum APIKeyCheck {
    /// Trim spaces, newlines, zero-width characters and surrounding quotes.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { "\u{200B}\u{200C}\u{200D}\u{FEFF}".contains($0) }
        for quote in ["\"", "'", "“", "”", "‘", "’"] where s.hasPrefix(quote) || s.hasSuffix(quote) {
            if s.hasPrefix(quote) { s.removeFirst() }
            if s.hasSuffix(quote) { s.removeLast() }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short warning for keys that look wrong, or nil.
    static func warning(for key: String, kind: EndpointKind, baseURL: URL?) -> String? {
        guard !key.isEmpty else { return nil }
        if key.contains(where: { $0.isWhitespace }) {
            return "The key contains a space or line break. Check that the paste is a single key."
        }
        switch kind {
        case .anthropic where !key.hasPrefix("sk-ant-"):
            return "Anthropic keys start with sk-ant-. This may be the wrong key."
        case .openAICompatible where baseURL?.host == "api.openai.com" && !key.hasPrefix("sk-"):
            return "OpenAI keys start with sk-. This may be the wrong key."
        default:
            return nil
        }
    }

    /// Enough of the key to recognise it: first 10 and last 4 characters.
    static func masked(_ key: String) -> String {
        guard key.count > 16 else { return String(key.prefix(3)) + "…" }
        return String(key.prefix(10)) + "…" + String(key.suffix(4))
    }
}
