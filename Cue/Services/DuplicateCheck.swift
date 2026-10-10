import Foundation

/// Whether what the user typed is a card already on the wall in other words ("雨伞" for "umbrella", "能刷卡吗" for "Do
/// you take cards?"), so the wall shows that card at once instead of writing and drawing a new one (user, 2026-10-07:
/// "提前认出重复的词"). One question to OpenAI's Decisions API (gpt-6-luna), with the wall's cards as its choices: much
/// faster than a written answer, and only its input is billed, at $0.10 per million tokens (a fraction of a hundredth
/// of a cent for a wall of fifty cards).
enum DuplicateCheck {
    struct Card {
        var id: UUID
        var headword: String
        /// The card's Chinese line.
        var meaning: String
        /// What the user first typed for it, when that was something else.
        var typed: String?
    }

    /// The model's answer: the choice it made, how sure it is, and the card that choice is, if any.
    struct Answer {
        var choice: String
        var confidence: Double
        var probabilities: [(value: String, probability: Double)]
        var card: UUID?
    }

    /// How sure the model must be before the wall shows an old card instead of writing a new one: showing the wrong
    /// card is worse than writing a word twice. Tuned on 2026-10-07 with 28 inputs against a wall of 45 cards: at 0.8
    /// it caught 11 of 13 repeats ("能刷卡吗" for "Do you take cards?" at 0.98) and took nothing new for a card; the
    /// two it let through, single words ("伞", "Umbrellas"), were then caught by their headword. Its wrong guesses
    /// scored 0.48 ("下雨了" for "umbrella") and 0.70 ("fever" for "have a slight fever").
    static let threshold = 0.8

    private static let new = "new"

    private static let instructions = Prompts.text("decide-instructions")

    /// Asks about what is being typed as soon as the typing pauses, so that the answer is usually in by the time
    /// Return is pressed and the wall can at once add a new card or show the one it has (user, 2026-10-07, of the
    /// quarter to half a second, now and then a second, it took after Return: "我们有更好的方式处理这 0 点几秒到 1 秒钟
    /// 吗"). Adding the card at once and taking it away again when it turned out to be one the wall had was tried
    /// first: "这种先加入再消失的状况，很不优雅". A question costs a hundredth of a cent or less; a word typed takes a few.
    @MainActor
    final class Lookahead {
        private var text = ""
        private var task: Task<UUID?, Never>?
        /// Whether the question about `text` has gone out, rather than waiting for the typing to pause.
        private var asked = false

        /// What the field says now. `cards` is read when the question goes out.
        func typed(_ input: String, among cards: @escaping () -> [Card]) {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != self.text else { return }
            self.text = text
            task?.cancel()
            task = nil
            asked = false
            guard !text.isEmpty else { return }
            task = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return nil }
                asked = true
                return try? await DuplicateCheck.card(for: text, among: cards())
            }
        }

        /// The question already out about `text`, handed over for its answer, or nil if none is: then the caller
        /// asks. Either way the field is left to the next word.
        func take(_ text: String) -> Task<UUID?, Never>? {
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

    /// The card the input means, or nil for anything new.
    static func card(for input: String, among cards: [Card]) async throws -> UUID? {
        guard let answer = try await ask(input, among: cards), answer.confidence >= threshold else { return nil }
        return answer.card
    }

    /// The model's answer, or nil with no cards to choose from.
    static func ask(_ input: String, among cards: [Card]) async throws -> Answer? {
        let access = try AIAccess.require()
        // One choice per headword; a headword on two cards stands for the first.
        var ids: [String: UUID] = [:]
        var choices: [[String: String]] = []
        for card in cards where ids[card.headword] == nil && card.headword != new {
            ids[card.headword] = card.id
            var description = card.meaning
            if let typed = card.typed, typed.caseInsensitiveCompare(card.headword) != .orderedSame {
                description += " (first typed as “\(typed)”)"
            }
            choices.append(["value": card.headword, "description": description])
        }
        guard !choices.isEmpty else { return nil }
        choices.append(["value": new, "description": "None of the saved cards: something not saved yet."])

        // A quick question, usually answered in a quarter to half a second: if it takes longer than this, the word is
        // simply written as a new one.
        var request: URLRequest
        switch access {
        case .ownKey(let key):
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/decisions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.5
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6-luna",
                "input": input,
                "questions": [["type": "choice", "name": "card", "instructions": instructions, "choices": choices]],
            ] as [String: Any])
        case .points:
            request = try CueServer.request("v1/decide", json: ["input": input, "choices": choices], timeout: 2.5)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw OpenAIError.server(message ?? "The decision service returned an error.")
        }
        guard let answer = try JSONDecoder().decode(Response.self, from: data).answers.first,
              let choice = answer.choice else {
            throw OpenAIError.server("The decision service returned no answer.")
        }
        return Answer(choice: choice, confidence: answer.confidence ?? 0,
                      probabilities: (answer.probabilities ?? []).map { ($0.value, $0.probability) }
                          .sorted { $0.probability > $1.probability },
                      card: ids[choice])
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            struct Option: Decodable {
                var value: String
                var probability: Double
            }
            var choice: String?
            var probabilities: [Option]?
            var confidence: Double?
        }
        var answers: [Answer]
    }
}
