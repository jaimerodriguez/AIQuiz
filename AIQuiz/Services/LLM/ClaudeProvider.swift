import Foundation

struct ClaudeProvider: LLMProvider {
    var id: ProviderID { .claude }
    var isAvailable: Bool { apiKey != nil }
    var maxSourceCharacters: Int { 100_000 }

    let apiKey: String?
    let model: String
    let session: URLSession

    init(apiKey: String?, model: String = "claude-opus-4-7", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func generateQuiz(_ req: QuizGenRequest) async throws -> QuizPayload {
        try enforceLimit(req.sourceContent)
        let raw = try await messages(
            system: PromptBuilder.quizSystem(),
            user: PromptBuilder.quizUser(req),
            prefill: "{"
        )
        do {
            return try LLMResponseParser.decode("{" + raw, as: QuizFile.self).quiz
        } catch {
            let retry = try await messages(
                system: PromptBuilder.quizSystem(),
                user: PromptBuilder.quizUser(req) + "\n\nThe previous response could not be decoded: \(error.localizedDescription). Return only the JSON object exactly matching the schema.",
                prefill: "{"
            )
            return try LLMResponseParser.decode("{" + retry, as: QuizFile.self).quiz
        }
    }

    func judgeAnswer(_ req: JudgeRequest) async throws -> JudgeVerdict {
        let raw = try await messages(
            system: PromptBuilder.judgeSystem(),
            user: PromptBuilder.judgeUser(req),
            prefill: "{"
        )
        let json: JudgeJSON = try LLMResponseParser.decode("{" + raw)
        return json.toVerdict()
    }

    private func messages(system: String, user: String, prefill: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey(.claude) }

        var msgs: [[String: Any]] = [
            ["role": "user", "content": user]
        ]
        if let prefill {
            msgs.append(["role": "assistant", "content": prefill])
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": msgs,
            "temperature": 0.4
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw LLMError.requestFailed("Claude HTTP \(http.statusCode): \(snippet)")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else {
            throw LLMError.malformedResponse("missing content[0].text")
        }
        return text
    }
}
