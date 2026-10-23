import Foundation

/// Narrows a provider's model list to models that can answer Chat Completions requests.
/// OpenAI's `/models` also returns embedding, speech, image, video, realtime and moderation
/// models, completions-only `-instruct` models, and `-codex` / `-pro` models that only work
/// through the Responses API. Offering those in the picker leads to confusing failures.
/// Markers were checked against a real OpenAI account's list on 2026-10-22.
public enum ModelListFilter {
    static let nonChatMarkers = [
        "embed", "tts", "whisper", "dall-e", "transcribe", "moderation",
        "realtime", "audio", "image", "search", "davinci", "babbage", "computer-use",
        "instruct", "codex", "sora", "gpt-live"
    ]

    /// Responses-API-only families, matched as a `-pro` segment so names like "prod" are kept.
    static let nonChatSegments = ["-pro"]

    /// Chat-capable ids, in their original order. If the filter would remove everything,
    /// the original list is returned unchanged.
    public static func chatModels(_ ids: [String]) -> [String] {
        let filtered = ids.filter { id in
            let lower = id.lowercased()
            if nonChatMarkers.contains(where: { lower.contains($0) }) { return false }
            return !nonChatSegments.contains { segment in
                lower.hasSuffix(segment) || lower.contains(segment + "-")
            }
        }
        return filtered.isEmpty ? ids : filtered
    }
}
