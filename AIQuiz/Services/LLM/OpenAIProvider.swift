import Foundation

struct OpenAIProvider: LLMProvider {
    var id: ProviderID { .openAI }
    var isAvailable: Bool { apiKey != nil }
    var maxSourceCharacters: Int { 100_000 }

    let apiKey: String?
    let model: String
    let session: URLSession

    init(apiKey: String?, model: String = "gpt-4o", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func generateQuiz(_ req: QuizGenRequest) async throws -> QuizPayload {
        try enforceLimit(req.sourceContent)
        let raw = try await chat(
            system: PromptBuilder.quizSystem(),
            user: PromptBuilder.quizUser(req),
            jsonObject: true
        )
        do {
            return try LLMResponseParser.decode(raw, as: QuizFile.self).quiz
        } catch {
            // One retry with the parser error included.
            let retry = try await chat(
                system: PromptBuilder.quizSystem(),
                user: PromptBuilder.quizUser(req) + "\n\nThe previous response could not be decoded: \(error.localizedDescription). Return only the JSON object exactly matching the schema.",
                jsonObject: true
            )
            return try LLMResponseParser.decode(retry, as: QuizFile.self).quiz
        }
    }

    func judgeAnswer(_ req: JudgeRequest) async throws -> JudgeVerdict {
        let raw = try await chat(
            system: PromptBuilder.judgeSystem(),
            user: PromptBuilder.judgeUser(req),
            jsonObject: true
        )
        let json: JudgeJSON = try LLMResponseParser.decode(raw)
        return json.toVerdict()
    }

    private func chat(system: String, user: String, jsonObject: Bool) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey(.openAI) }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.4
        ]
        if jsonObject {
            body["response_format"] = ["type": "json_object"]
        }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw LLMError.requestFailed("OpenAI HTTP \(http.statusCode): \(snippet)")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let msg = choices.first?["message"] as? [String: Any],
            let content = msg["content"] as? String
        else {
            throw LLMError.malformedResponse("missing choices[0].message.content")
        }
        return content
    }
}
