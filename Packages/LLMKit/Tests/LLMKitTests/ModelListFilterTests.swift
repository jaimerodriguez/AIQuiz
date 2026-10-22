import Testing
@testable import LLMKit

@Suite("ModelListFilter")
struct ModelListFilterTests {
    @Test("drops embedding, speech, image and moderation models, keeping order")
    func filters() {
        let ids = [
            "gpt-5", "text-embedding-3-large", "tts-1", "whisper-1", "dall-e-3", "gpt-image-1",
            "omni-moderation-latest", "gpt-4o-realtime-preview", "gpt-4o-mini-transcribe", "o4-mini", "babbage-002"
        ]
        #expect(ModelListFilter.chatModels(ids) == ["gpt-5", "o4-mini"])
    }

    @Test("drops completions-only, Responses-only, video and realtime models seen on a real account")
    func responsesOnlyAndOthers() {
        let ids = [
            "gpt-3.5-turbo", "gpt-3.5-turbo-instruct", "gpt-3.5-turbo-instruct-0914",
            "gpt-5", "gpt-5-codex", "gpt-5.1-codex-max", "gpt-5-pro", "gpt-5-pro-2025-10-06", "o1-pro",
            "gpt-5.5", "gpt-5.5-pro-2026-04-23", "gpt-6-luna", "sora-2", "sora-2-pro", "gpt-live-1",
            "gpt-5.4-mini", "chat-latest"
        ]
        #expect(ModelListFilter.chatModels(ids) == ["gpt-3.5-turbo", "gpt-5", "gpt-5.5", "gpt-6-luna", "gpt-5.4-mini", "chat-latest"])
    }

    @Test("a -pro segment is required; names merely containing 'pro' are kept")
    func proSegment() {
        #expect(ModelListFilter.chatModels(["llama-prod-8b", "mistral-pro"]) == ["llama-prod-8b"])
    }

    @Test("Anthropic and local model ids pass through")
    func passThrough() {
        let ids = ["claude-opus-5-5", "claude-haiku-5-5", "llama3.3:70b", "qwen2.5-coder"]
        #expect(ModelListFilter.chatModels(ids) == ids)
    }

    @Test("an all-filtered list is returned unchanged")
    func neverEmpty() {
        #expect(ModelListFilter.chatModels(["nomic-embed-text"]) == ["nomic-embed-text"])
        #expect(ModelListFilter.chatModels([]) == [])
    }
}
