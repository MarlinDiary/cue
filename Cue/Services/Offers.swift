import Foundation
import SwiftUI

/// After an answer, the English word or expression it turned on, offered to keep on the wall: what was asked how to say,
/// a word asked about, or the new one the answer was about. Never one only mentioned along the way, a basic word or one
/// already saved; most answers offer nothing, none more than two (user, 2026-10-18: "在非常合适的时候，不能就是硬弄…给一张
/// 卡片…允许我们把单词加入到我们的词库"). Asked of a small model once the answer is written, apart from the conversation,
/// so the answer itself is never held up or changed by it.
nonisolated enum OfferClient {
    static func offers(question: String, answer: String, saved: [String]) async throws -> [Chat.Offer] {
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            let schema = try JSONSerialization.jsonObject(with: Data(Prompts.text("offer-schema").utf8))
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6-luna",
                "reasoning": ["effort": "low"],
                "store": false,
                "instructions": Prompts.text("offer-instructions", ["saved": saved.joined(separator: "\n")]),
                "input": "Question:\n\(question)\n\nAnswer:\n\(answer)",
                "text": ["format": ["type": "json_schema", "name": "offers", "schema": schema, "strict": true]],
            ] as [String: Any])
        case .points:
            // The server asks in the same words, from the same prompts, and answers as OpenAI does.
            request = try CueServer.request("v1/offer", json: ["question": question, "answer": answer, "saved": saved],
                                            timeout: 30)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try CueServer.check(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server((object?["error"] as? [String: Any])?["message"] as? String ?? "No offer came.")
        }
        let output = (object?["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let reply = output.first { $0["type"] as? String == "output_text" }?["text"] as? String ?? ""
        struct Reply: Decodable { let offers: [Chat.Offer] }
        return try JSONDecoder().decode(Reply.self, from: Data(reply.utf8)).offers
    }

    /// An offer's meaning without its part of speech, for its capsule: "adj. 直率的" gives "直率的".
    static func shortMeaning(_ meaning: String) -> String {
        let pieces = meaning.split(separator: " ")
        let kept = pieces.drop { $0.hasSuffix(".") && $0.allSatisfy { $0.isASCII } }
        return kept.isEmpty ? meaning : kept.joined(separator: " ")
    }
}

extension EnvironmentValues {
    /// Puts a word on the wall as if it had been typed into the wall's field (`HomeView.add`): given by the wall to
    /// the conversations opened from it, for the words their answers offer.
    @Entry var keepOnWall: ((String) -> Void)? = nil
}
