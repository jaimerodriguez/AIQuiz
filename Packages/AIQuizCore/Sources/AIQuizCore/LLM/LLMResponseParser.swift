import Foundation

/// Thrown when a model response holds no decodable JSON object.
public struct LLMResponseParseError: LocalizedError, Sendable, Equatable {
    public let detail: String

    public init(_ detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? {
        "Couldn't read the model's response: \(detail)"
    }
}

/// Tolerant extraction of a JSON object from model text: strips markdown fences,
/// then returns the first balanced `{...}` block, ignoring braces inside JSON strings.
public enum LLMResponseParser {
    public static func decode<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
        guard let json = extractJSONObject(from: raw) else {
            throw LLMResponseParseError("no JSON object found")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch let error as DecodingError {
            throw LLMResponseParseError(describe(error))
        } catch {
            throw LLMResponseParseError(String(describing: error))
        }
    }

    public static func extractJSONObject(from raw: String) -> String? {
        let text = stripFences(raw)

        var depth = 0
        var startIdx: String.Index?
        var inString = false
        var escaped = false

        for idx in text.indices {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            switch ch {
            case "\"":
                if depth > 0 { inString = true }
            case "{":
                if depth == 0 { startIdx = idx }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start = startIdx {
                    return String(text[start...idx])
                }
            default:
                break
            }
        }
        return nil
    }

    /// If the text contains a ``` fence, return the content of the first fenced block.
    static func stripFences(_ raw: String) -> String {
        guard let start = raw.range(of: "```") else { return raw }
        var text = raw[start.upperBound...]
        // Skip an optional language tag on the same line.
        if let newline = text.firstIndex(of: "\n") {
            text = text[text.index(after: newline)...]
        }
        if let end = text.range(of: "```") {
            text = text[..<end.lowerBound]
        }
        return String(text)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(let type, let ctx):
            return "expected \(type) at \(path(ctx))"
        case .valueNotFound(let type, let ctx):
            return "missing \(type) at \(path(ctx))"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "root" : p
    }
}
