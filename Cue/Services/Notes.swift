import Foundation

/// After an answer in a word's conversation, what is worth keeping on its card, if anything: the question as it was
/// meant and the gist of the answer (`WordNote`), offered under the answer for the user to keep. Nothing for a greeting,
/// thanks or small talk (user, 2026-10-18: "万一我说个'你好'，它也说这个添加到下面…这不瞎说吗？"). Asked of a small model
/// once the answer is written, apart from the conversation, as the words answers offer are (`OfferClient`).
nonisolated enum NoteClient {
    static func note(about headword: String, question: String, answer: String) async throws -> WordNote? {
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            let schema = try JSONSerialization.jsonObject(with: Data(Prompts.text("note-schema").utf8))
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6-luna",
                "reasoning": ["effort": "low"],
                "store": false,
                "instructions": Prompts.text("note-instructions", ["headword": headword]),
                "input": "Question:\n\(question)\n\nAnswer:\n\(answer)",
                "text": ["format": ["type": "json_schema", "name": "note", "schema": schema, "strict": true]],
            ] as [String: Any])
        case .points:
            // The server asks in the same words, from the same prompts, and answers as OpenAI does.
            request = try CueServer.request("v1/note", json: ["headword": headword, "question": question,
                                                             "answer": answer], timeout: 30)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server((object?["error"] as? [String: Any])?["message"] as? String ?? "No note came.")
        }
        let output = (object?["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let reply = output.first { $0["type"] as? String == "output_text" }?["text"] as? String ?? ""
        struct Reply: Decodable { let keep: Bool; let question: String; let answer: String }
        let found = try JSONDecoder().decode(Reply.self, from: Data(reply.utf8))
        let kept = (question: found.question.trimmingCharacters(in: .whitespacesAndNewlines),
                    answer: found.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard found.keep, !kept.question.isEmpty, !kept.answer.isEmpty else { return nil }
        return WordNote(id: UUID(), question: kept.question, answer: kept.answer)
    }
}
