import Foundation
import SwiftData

/// One conversation with AI: about the whole wall, or about one word. Each place keeps one, as long as the user likes,
/// until they start it over (user, 2026-10-07: "我希望是可以长聊天的…在外部的话，要有入口。然后进入每个单词之后…也能同样地
/// 有入口"; chose one long conversation per place over a ChatGPT-style list).
nonisolated struct Chat: Codable {
    struct Message: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case user, assistant }
        var id = UUID()
        var role: Role
        var text: String
    }

    var messages: [Message] = []
}

/// The conversations, one per place: "wall" for the wall's, and a word's id for that word's. They are kept in the
/// store with the words (`Conversation`), and so in iCloud with them (user, 2026-10-08: "做 iCloud 同步吧"); they were
/// files of their own in Application Support/Chats, moved in once. An answer streams into its conversation as AI
/// writes it, kept here meanwhile and stored as it starts and as it ends, and goes on if the conversation is closed.
@Observable
final class Chats {
    static let shared = Chats()

    /// The conversation about the whole wall.
    static let wall = "wall"

    /// Where the conversations are kept: the app's store, given as the app starts.
    @ObservationIgnored private var context: ModelContext?
    private var loaded: [String: Chat] = [:]
    /// Every message each conversation has had here since it was read from the store: a message kept in the store
    /// that isn't among them came from another device.
    @ObservationIgnored private var known: [String: Set<UUID>] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Conversations with an answer being written, and why the last answer didn't come, if it didn't.
    private(set) var answering: Set<String> = []
    private(set) var failures: [String: String] = [:]
    /// What was being written in each conversation and not yet sent: still there when it is opened again, for as long
    /// as the app runs.
    var drafts: [String: String] = [:]

    /// How many of the latest messages go with each question: a long conversation's oldest stay on screen but no
    /// longer cost anything.
    private static let remembered = 60

    func messages(in key: String) -> [Chat.Message] { loaded[key]?.messages ?? [] }

    /// Starts keeping the conversations in `context`, moving in any still kept as files.
    func attach(_ context: ModelContext) {
        self.context = context
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.directory,
                                                                       includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            if stored(key) == nil, let data = try? Data(contentsOf: file) {
                let record = Conversation(key: key)
                record.data = data
                context.insert(record)
            }
        }
        try? context.save()
        try? FileManager.default.removeItem(at: Self.directory)
    }

    /// Reads a conversation from the store as it is opened, so what was said on another device since shows; not while
    /// an answer is being written into it here.
    func open(_ key: String) {
        guard !answering.contains(key) else { return }
        var chat = stored(key)?.data.flatMap { try? JSONDecoder().decode(Chat.self, from: $0) } ?? Chat()
        #if DEBUG
        // `-seedChat N`: N questions and their answers before the wall's conversation, to try a long one; never kept.
        let seeded = UserDefaults.standard.integer(forKey: "seedChat")
        if seeded > 0, key == Self.wall { chat.messages = Self.seed(seeded) + chat.messages }
        #endif
        loaded[key] = chat
        known[key] = Set(chat.messages.map(\.id))
    }

    /// Asks `text` in the conversation, AI answering with what it knows of the wall or the word, `context`.
    /// Returns the question as it stands in the conversation.
    @discardableResult
    func send(_ text: String, in key: String, context: ChatContext) -> Chat.Message.ID? {
        open(key)
        guard !answering.contains(key), var chat = loaded[key] else { return nil }
        let question = Chat.Message(role: .user, text: text)
        chat.messages.append(question)
        let history = Array(chat.messages.suffix(Self.remembered))
        let answer = Chat.Message(role: .assistant, text: "")
        chat.messages.append(answer)
        loaded[key] = chat
        known[key, default: []].formUnion([question.id, answer.id])
        failures[key] = nil
        answering.insert(key)
        save(key)
        tasks[key] = Task {
            defer {
                answering.remove(key)
                tasks[key] = nil
                // An answer that never began leaves nothing behind it.
                if loaded[key]?.messages.last?.role == .assistant, loaded[key]?.messages.last?.text.isEmpty == true {
                    loaded[key]?.messages.removeLast()
                }
                save(key)
            }
            do {
                let onDelta: @MainActor (String) -> Void = { delta in
                    guard let last = self.loaded[key]?.messages.indices.last else { return }
                    self.loaded[key]?.messages[last].text += delta
                }
                #if DEBUG
                // `-rehearseChat YES`: a long answer written here, in bursts as AI's come, to watch a conversation
                // without paying for one.
                if UserDefaults.standard.bool(forKey: "rehearseChat") {
                    try await ChatClient.rehearse(short: text.count <= 6, onDelta: onDelta)
                    return
                }
                #endif
                try await ChatClient.stream(history, context: context, onDelta: onDelta)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                failures[key] = error.localizedDescription
            }
        }
        return question.id
    }

    /// Stops the answer being written, keeping what has come of it.
    func stop(_ key: String) {
        tasks[key]?.cancel()
    }

    /// Deletes the conversation, here and on the user's other devices.
    func clear(_ key: String) {
        stop(key)
        loaded[key] = Chat()
        known[key] = []
        failures[key] = nil
        delete(key)
    }

    /// A word's conversation goes with it.
    func forget(_ key: String) {
        stop(key)
        loaded[key] = nil
        known[key] = nil
        failures[key] = nil
        delete(key)
    }

    /// A conversation carried over to another place: a card that turned into one the wall had takes that card's.
    func move(_ key: String, to other: String) {
        stop(key)
        open(key)
        delete(other)
        for record in records(key) { record.key = other }
        try? context?.save()
        loaded[other] = loaded[key]
        known[other] = known[key]
        loaded[key] = nil
        known[key] = nil
    }

    /// Stores the conversation as it is here, with any messages kept for it that came from another device first: a
    /// conversation begun here while the one in iCloud was still on its way (just after the app was installed again)
    /// goes on from that one rather than taking its place. One with nothing in it isn't kept.
    private func save(_ key: String) {
        #if DEBUG
        if UserDefaults.standard.integer(forKey: "seedChat") > 0 { return }
        #endif
        guard let context, var chat = loaded[key] else { return }
        guard !chat.messages.isEmpty else { return delete(key) }
        let record = stored(key) ?? {
            let record = Conversation(key: key)
            context.insert(record)
            return record
        }()
        let kept = record.data.flatMap { try? JSONDecoder().decode(Chat.self, from: $0) }?.messages ?? []
        let foreign = kept.filter { !(known[key]?.contains($0.id) ?? false) }
        if !foreign.isEmpty {
            chat.messages = foreign + chat.messages
            loaded[key] = chat
            known[key, default: []].formUnion(foreign.map(\.id))
        }
        record.data = try? JSONEncoder().encode(chat)
        record.updatedAt = .now
        try? context.save()
    }

    /// The conversation kept for `key`. Two devices that each began one before they synced have two: they are joined
    /// into the older, its messages first.
    private func stored(_ key: String) -> Conversation? {
        let records = records(key)
        guard let first = records.first else { return nil }
        if records.count > 1 {
            var seen = Set<UUID>()
            var joined = Chat()
            for record in records {
                let chat = record.data.flatMap { try? JSONDecoder().decode(Chat.self, from: $0) } ?? Chat()
                joined.messages += chat.messages.filter { seen.insert($0.id).inserted }
            }
            first.data = try? JSONEncoder().encode(joined)
            for record in records.dropFirst() { context?.delete(record) }
            try? context?.save()
        }
        return first
    }

    private func records(_ key: String) -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.key == key },
                                                       sortBy: [SortDescriptor(\.createdAt)])
        return (try? context?.fetch(descriptor)) ?? []
    }

    private func delete(_ key: String) {
        for record in records(key) { context?.delete(record) }
        try? context?.save()
    }

    /// Where the conversations were kept before they were kept in the store.
    private static let directory = URL.applicationSupportDirectory.appending(path: "Chats")
}

/// Talks to AI for `Chats`: the conversation so far goes up, and the answer comes back as it is written.
nonisolated enum ChatClient {
    static func stream(_ messages: [Chat.Message], context: ChatContext,
                       onDelta: @MainActor (String) -> Void) async throws {
        let input = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var request: URLRequest
        switch try AIAccess.require() {
        case .ownKey(let key):
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-6.1-sol",
                "reasoning": ["effort": "low"],
                "store": false,
                "stream": true,
                "instructions": context.instructions,
                "input": input,
            ] as [String: Any])
        case .points:
            // The server puts the instructions together from the same prompts, around what the conversation is about.
            request = try CueServer.request("v1/chat", json: ["kind": context.kind.rawValue, "lines": context.lines,
                                                             "messages": input], timeout: 120)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try CueServer.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server(try await EventStream.errorMessage(in: bytes) ?? "AI didn’t answer.")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = EventStream.event(from: line) else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String { await onDelta(delta) }
            case "response.completed":
                return
            case "response.failed", "response.incomplete", "error":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? event["message"] as? String
                throw OpenAIError.server(message ?? "AI didn’t answer.")
            default:
                _ = CueServer.note(event)
            }
        }
    }
}

#if DEBUG
extension ChatClient {
    /// An answer as AI might write one, after a second and a half of thought, in pieces of one to a dozen characters
    /// coming 20 to 160 ms apart; `-rehearsePace 4` writes it four times as slowly. `short`: two lines, as to a question
    /// of a few characters AI couldn't make out.
    static func rehearse(short: Bool, onDelta: @MainActor (String) -> Void) async throws {
        let pace = max(UserDefaults.standard.double(forKey: "rehearsePace"), 1)
        let answer = short ? "这句我没看懂，是语音输入识别错了吗？你可以再发一次。" : rehearsal
        try await Task.sleep(for: .seconds(1.5))
        var rest = Substring(answer)
        while !rest.isEmpty {
            try Task.checkCancellation()
            let piece = rest.prefix(Int.random(in: 1...12))
            rest = rest.dropFirst(piece.count)
            await onDelta(String(piece))
            try await Task.sleep(for: .milliseconds(Int(Double(Int.random(in: 20...160)) * pace)))
        }
    }

    /// A long answer as AI might write one.
    static let rehearsal = """
            candid 的意思是"坦率的、直言不讳的"，形容一个人说话不绕弯子，把真实的想法直接说出来。

            1. She was candid about her mistakes. 她坦白地承认了自己的错误。
            2. Can I be candid with you? 我能跟你说句实话吗？
            3. Thanks for your candid feedback. 谢谢你坦率的反馈。

            它还有一个常见的用法：a candid photo，指"抓拍的照片"，也就是人物没有摆姿势、在自然状态下被拍下的照片。

            和意思相近的词比较：honest 强调不说谎；frank 和 candid 都是"直说"，但 frank 的语气更直接，有时显得生硬；candid 更中性，常带一点"难得坦诚"的意味。比如面试官说 I appreciate your candid answer，是在夸你回答得坦诚。

            记忆小窍门：candid 和 candle（蜡烛）同源，都来自拉丁语 candidus，意思是"白色的、明亮的"。心里亮堂、没有隐藏，就是 candid。

            小练习：试着用 candid 描述一位你认识的、说话很直接的朋友，比如 My roommate is always candid about what she thinks of my cooking.
            """
}

extension Chats {
    /// `n` questions, each with its answer, long and short in turn, for `-seedChat`: ids fixed by their place, so the
    /// conversation is the same each time it is read.
    static func seed(_ n: Int) -> [Chat.Message] {
        (0..<n).flatMap { i -> [Chat.Message] in
            let id = { (k: Int) in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 2 * i + k))! }
            return [Chat.Message(id: id(0), role: .user, text: "Question \(i + 1)?"),
                    Chat.Message(id: id(1), role: .assistant,
                                 text: i % 2 == 0 ? ChatClient.rehearsal : "Answer \(i + 1): 简短的回答。")]
        }
    }
}
#endif

/// What a conversation is about, for AI: the wall's words or one word's page, as lines. Put together with how AI talks
/// into its instructions, here for the user's own key and on Cue's server alike, from the same prompts.
nonisolated struct ChatContext {
    enum Kind: String {
        case wall, word
    }

    var kind: Kind
    var lines: [String]

    /// How AI talks (chat-manner), then what the conversation is about.
    var instructions: String {
        Prompts.text("chat-manner") + Prompts.text(kind == .wall ? "chat-wall" : "chat-word",
                                                   [kind == .wall ? "saved" : "page": lines.joined(separator: "\n")])
    }
}

/// What AI knows going into a conversation.
enum ChatPrompt {
    /// For the wall's conversation: every word on it, newest first, with the Chinese on its card.
    static func wall(_ words: [Word]) -> ChatContext {
        ChatContext(kind: .wall, lines: words.compactMap { word in word.entry.map { "\(word.text) — \($0.summary)" } })
    }

    /// For a word's conversation: everything its page says.
    static func word(_ word: Word) -> ChatContext {
        var page = ["Headword: \(word.text)"]
        if let entry = word.entry {
            page.append("On its card: \(entry.summary)")
            if let ipa = entry.phoneticUS, !ipa.isEmpty { page.append("Pronunciation: /\(ipa)/") }
            for part in entry.parts {
                for sense in part.senses {
                    var line = "\(part.pos): \(sense.chinese)"
                    if let english = sense.english { line += " — \(english)" }
                    if let example = sense.example { line += ". Example: \(example)" }
                    page.append(line)
                }
            }
            for line in entry.exchange ?? [] { page.append("Said as: \(line.english) \(line.chinese)") }
            if let collocations = entry.collocations, !collocations.isEmpty {
                page.append("Phrases: " + collocations.map { "\($0.phrase) (\($0.chinese))" }.joined(separator: "; "))
            }
            if let note = entry.note { page.append("Usage: \(note)") }
            if let etymology = entry.etymology { page.append("Origin: \(etymology)") }
        }
        return ChatContext(kind: .word, lines: page)
    }
}
