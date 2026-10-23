import Foundation

/// Typed failures from any endpoint (SPEC §7.3). `errorDescription` is safe to show users:
/// it never contains response bodies. `logDescription` carries the detail for logs.
public enum LLMError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey(endpoint: String)
    case noModelSelected(endpoint: String)
    case endpointUnavailable(String)
    case unauthorized
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case contextTooLong
    case badRequest(status: Int, detail: String)
    case server(status: Int)
    case network(String)
    case timedOut
    case cancelled
    case refused(category: String?)
    case malformedResponse(String)
    case outputTruncated

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "\(name) needs an API key. Add one in Settings → AI endpoints."
        case .noModelSelected(let name):
            return "\(name) has no model selected. Open Settings → AI endpoints, tap Test connection and pick a model."
        case .endpointUnavailable(let reason):
            return "This AI endpoint is unavailable: \(reason)"
        case .unauthorized:
            return "The AI service rejected the API key. Check it in Settings → AI endpoints."
        case .notFound:
            return "The AI service couldn't find that model or address. Check the endpoint's model and base URL."
        case .rateLimited:
            return "The AI service is rate-limiting requests. Wait a moment and try again."
        case .contextTooLong:
            return "The source is too long for this model. Shorten it or route generation to a model with a larger context window."
        case .badRequest(let status, _):
            return "The AI service rejected the request (HTTP \(status))."
        case .server(let status):
            return "The AI service had a problem (HTTP \(status)). Try again shortly."
        case .network:
            return "Couldn't reach the AI service. Check your connection and the endpoint address."
        case .timedOut:
            return "The AI service took too long to respond. Try again."
        case .cancelled:
            return "Cancelled."
        case .refused:
            return "The model declined this request."
        case .malformedResponse:
            return "The model's response couldn't be read. Try again, or try a different model."
        case .outputTruncated:
            return "The model's response was cut off before it finished. Try fewer cards or a shorter source."
        }
    }

    /// Full detail for logs. Never show to users.
    public var logDescription: String {
        switch self {
        case .badRequest(let status, let detail): return "badRequest(\(status)): \(detail)"
        case .network(let detail): return "network: \(detail)"
        case .malformedResponse(let detail): return "malformedResponse: \(detail)"
        case .refused(let category): return "refused(\(category ?? "nil"))"
        case .rateLimited(let after): return "rateLimited(retryAfter: \(after.map { String($0) } ?? "nil"))"
        default: return String(describing: self)
        }
    }

    /// Transient failures worth retrying against the same endpoint (SPEC §8.5).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network, .timedOut: return true
        default: return false
        }
    }

    /// Failures where trying the purpose's fallback endpoint might succeed (SPEC §8.2).
    public var shouldTryFallback: Bool {
        switch self {
        case .rateLimited, .server, .network, .timedOut, .endpointUnavailable, .refused, .contextTooLong: return true
        default: return false
        }
    }
}
