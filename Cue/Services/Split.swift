import Foundation

/// What was typed into the wall's field, as the separate things it asks a card for: "candid、frank 和 blunt 分别是什么意思"
/// is three, "开会时想说推迟一下该怎么说" one (user, 2026-10-18: "用户…自然语言输了好几个东西。那这个是不是可以加好几张卡片";
/// two words compared are a card each). Whether it is several is a quick question (`isSeveral`), asked as the typing
/// pauses as whether it is a card the wall has is (`Lookahead`): a written answer takes a second and a half, which every
/// word typed in Chinese would have waited for before its card began to be written. Only then, and only for several, the
/// written answer (`items`), once the card for what was typed is up (`HomeView.add`).
nonisolated enum SplitClient {
    /// The most cards one line adds: a paragraph pasted by mistake would be dozens, each written and drawn.
    static let most = 10

    /// Whether `text` could ask for more than one card: anything but a single English word.
    static func mayHoldSeveral(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z'’\-]*$"#, options: .regularExpression) == nil
    }

    /// Asks whether what is being typed is several things as soon as the typing pauses, as `DuplicateCheck.Lookahead`
    /// asks whether it is a card the wall has, so the answer is usually in by the time Return is pressed.
    @MainActor
    final class Lookahead {
        private var text = ""
        private var task: Task<Bool, Never>?
        private var asked = false

        func typed(_ input: String) {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != self.text else { return }
            self.text = text
            task?.cancel()
            task = nil
            asked = false
            guard !text.isEmpty, mayHoldSeveral(text) else { return }
            task = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return false }
                asked = true
                return (try? await isSeveral(text)) ?? false
            }
        }

        /// The question already out about `text`, handed over for its answer, or nil if none is.
        func take(_ text: String) -> Task<Bool, Never>? {
            defer {
                self.text = ""
                task = nil
                asked = false
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == self.text, asked else {
                task?.cancel()
                return nil
            }
            return task
        }
    }

    /// Whether `text` asks for several cards: one quick question to OpenAI's Decisions API (gpt-6-luna), as
    /// `DuplicateCheck` asks, a quarter to half a second.
    static func isSeveral(_ text: String) async throws -> Bool {
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            let choices = try JSONSerialization.jsonObject(with: Data(Prompts.text("count-choices").utf8))
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/decisions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.5
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6-luna",
                "input": text,
                "questions": [["type": "choice", "name": "count", "instructions": Prompts.text("count-instructions"),
                               "choices": choices]],
            ] as [String: Any])
        case .points:
            request = try CueServer.request("v1/count", json: ["input": text], timeout: 2.5)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server((object?["error"] as? [String: Any])?["message"] as? String ?? "No answer came.")
        }
        let answer = (object?["answers"] as? [[String: Any]])?.first
        return answer?["choice"] as? String == "several"
    }

    /// The separate things `text` asks a card for, in the order typed, `most` at most; the text itself when it asks for
    /// one.
    static func items(in text: String) async throws -> [String] {
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            let schema = try JSONSerialization.jsonObject(with: Data(Prompts.text("split-schema").utf8))
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6-luna",
                "reasoning": ["effort": "low"],
                "store": false,
                "instructions": Prompts.text("split-instructions"),
                "input": text,
                "text": ["format": ["type": "json_schema", "name": "split", "schema": schema, "strict": true]],
            ] as [String: Any])
        case .points:
            // The server asks in the same words, from the same prompts, and answers as OpenAI does.
            request = try CueServer.request("v1/split", json: ["text": text], timeout: 30)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server((object?["error"] as? [String: Any])?["message"] as? String ?? "No answer came.")
        }
        let output = (object?["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let reply = output.first { $0["type"] as? String == "output_text" }?["text"] as? String ?? ""
        struct Reply: Decodable { let items: [String] }
        let items = try JSONDecoder().decode(Reply.self, from: Data(reply.utf8)).items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(items.prefix(most))
    }
}
