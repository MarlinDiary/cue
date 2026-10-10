import Foundation

/// Turns whatever the user typed into an English headword and writes its learner's-dictionary entry, with
/// GPT-6.1 Sol. Structured output makes the answer decode straight into `WordEntry`.
enum EntryGenerator {
    /// What a picture brief is: the entry's `pictureIdea`, and a brief written again when the image service turned
    /// one down (`saferPictureIdea`).
    private static let pictureBrief = Prompts.text("picture-brief")

    private static let instructions = Prompts.text("entry-instructions", ["pictureBrief": pictureBrief])

    /// The answer's shape. Written out as JSON rather than built from dictionaries, because the model writes the fields
    /// in this order and a Swift dictionary has none: the headword, its pronunciation and its meaning first, so the
    /// card and page have them within seconds, then the picture idea, so the picture can start while the rest of the
    /// entry is still being written.
    private static let schema = Prompts.text("entry-schema")

    /// The English word or expression the input stands for, and its entry. The entry streams in, and `onDraft` gets
    /// what has arrived each time another field is complete.
    /// `onDraft` returns whether to go on: the caller can stop the entry as it comes in, as when its headword turns
    /// out to be a card the wall already has. Stopped, it throws `CancellationError`.
    /// `fresh` asks for a new one even when Cue's server has the word in its shared library (a rewrite).
    static func entry(for input: String, fresh: Bool = false, onDraft: (EntryDraft) -> Bool = { _ in true })
        async throws -> (headword: String, entry: WordEntry) {
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("""
                {"model":"gpt-6.1-sol","reasoning":{"effort":"low"},"store":false,"stream":true,\
                "instructions":\(jsonString(instructions)),"input":\(jsonString(input)),\
                "text":{"format":{"type":"json_schema","name":"word_entry","strict":true,"schema":\(schema)}}}
                """.utf8)
        case .points:
            request = try CueServer.request("v1/entry", json: ["input": input, "fresh": fresh], timeout: 120)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try CueServer.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server(try await EventStream.errorMessage(in: bytes) ?? "The dictionary service returned an error.")
        }
        var text = ""
        var draft: EntryDraft?
        events: for try await line in bytes.lines {
            guard let event = EventStream.event(from: line) else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
                if let data = PartialJSON.completed(text),
                   let latest = try? JSONDecoder().decode(EntryDraft.self, from: data), latest != draft {
                    draft = latest
                    guard onDraft(latest) else {
                        bytes.task.cancel()
                        throw CancellationError()
                    }
                }
            case "response.completed":
                break events
            case "response.failed", "response.incomplete", "error":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? event["message"] as? String
                throw OpenAIError.server(message ?? "The dictionary service returned an error.")
            default:
                _ = CueServer.note(event)
            }
        }
        guard !text.isEmpty else { throw OpenAIError.server("The dictionary service didn’t return an entry.") }
        let answer = Data(text.utf8)
        let headword = try JSONDecoder().decode(Headword.self, from: answer).headword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = try JSONDecoder().decode(WordEntry.self, from: answer).styled(headword: headword)
        entry.version = WordEntry.currentVersion
        return (headword, entry)
    }

    /// A new brief for a picture the image service's safety system turned down: the same meaning, shown so that it
    /// passes. `refusal` is the service's answer, which says why when it can. The picture is drawn again from it without
    /// a word to the user (user, 2026-10-07: "不能直接给用户报错，而是去找到更不会出问题的提示词…假装…进行二次请求就行了").
    static func saferPictureIdea(_ idea: String, for headword: String, meaning: String?, refusal: String) async throws
        -> String {
        let access = try AIAccess.require()
        let instructions = Prompts.text("safer-brief-instructions", ["pictureBrief": pictureBrief])
        let input = """
            Word: \(headword)\(meaning.map { " (\($0))" } ?? "")
            Brief: \(idea)
            Safety system: \(refusal)
            """
        var request: URLRequest
        switch access {
        case .ownKey(let key):
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("""
                {"model":"gpt-6.1-sol","reasoning":{"effort":"low"},"store":false,\
                "instructions":\(jsonString(instructions)),"input":\(jsonString(input)),\
                "text":{"format":{"type":"json_schema","name":"picture_brief","strict":true,"schema":\
                {"type":"object","additionalProperties":false,"required":["brief"],\
                "properties":{"brief":{"type":"string"}}}}}}
                """.utf8)
        case .points:
            request = try CueServer.request("v1/brief", json: ["idea": idea, "headword": headword,
                                                              "meaning": meaning ?? "", "refusal": refusal], timeout: 60)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw OpenAIError.server(message ?? "The dictionary service returned an error.")
        }
        // The answer is the text of the message among the response's output.
        let text = (json?["output"] as? [[String: Any]])?
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .first { $0["type"] as? String == "output_text" }?["text"] as? String
        guard let text, let brief = try? JSONDecoder().decode(Brief.self, from: Data(text.utf8)).brief
            .trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty else {
            throw OpenAIError.server("The dictionary service didn’t return a brief.")
        }
        return brief
    }

    /// A string as a JSON string literal, quotes and escapes included.
    private static func jsonString(_ string: String) -> String {
        (try? JSONEncoder().encode(string)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private struct Headword: Decodable {
        var headword: String
    }

    private struct Brief: Decodable {
        var brief: String
    }
}

#if DEBUG
extension EntryGenerator {
    /// For `ModelLab`: the entry `model` writes at `effort` for `input`, as the raw JSON it answers with, not streamed,
    /// with the response's token usage and how long it took.
    static func labEntry(for input: String, model: String, effort: String) async throws
        -> (json: String, usage: [String: Any], seconds: Double) {
        guard let key = APIKeyStore.openAIKey else { throw OpenAIError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            {"model":\(jsonString(model)),"reasoning":{"effort":\(jsonString(effort))},"store":false,\
            "instructions":\(jsonString(instructions)),"input":\(jsonString(input)),\
            "text":{"format":{"type":"json_schema","name":"word_entry","strict":true,"schema":\(schema)}}}
            """.utf8)
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let seconds = Date().timeIntervalSince(start)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server(String(decoding: data, as: UTF8.self))
        }
        let text = (json?["output"] as? [[String: Any]])?
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .first { $0["type"] as? String == "output_text" }?["text"] as? String ?? ""
        return (text, json?["usage"] as? [String: Any] ?? [:], seconds)
    }
}
#endif
