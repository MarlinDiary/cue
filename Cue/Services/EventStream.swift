import Foundation

/// Reading OpenAI's streamed replies, which arrive as server-sent events: one JSON object per `data:` line.
nonisolated enum EventStream {
    /// The event a line carries, if it is a `data:` line.
    static func event(from line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
    }

    /// The service's own message in an error reply that was asked for as a stream but came back whole.
    static func errorMessage(in bytes: URLSession.AsyncBytes) async throws -> String? {
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String
    }
}
