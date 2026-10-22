import Foundation

/// Narrows a provider's model list to models that can answer chat requests. OpenAI's
/// `/models` returns embedding, speech, image and moderation models alongside chat models;
/// offering those in the model picker leads to confusing failures.
public enum ModelListFilter {
    static let nonChatMarkers = [
        "embed", "tts", "whisper", "dall-e", "transcribe", "moderation",
        "realtime", "audio", "image", "search", "davinci", "babbage", "computer-use"
    ]

    /// Chat-capable ids, in their original order. If the filter would remove everything,
    /// the original list is returned unchanged.
    public static func chatModels(_ ids: [String]) -> [String] {
        let filtered = ids.filter { id in
            let lower = id.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        }
        return filtered.isEmpty ? ids : filtered
    }
}
