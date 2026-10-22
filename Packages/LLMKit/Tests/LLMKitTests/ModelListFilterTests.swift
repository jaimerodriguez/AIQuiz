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
