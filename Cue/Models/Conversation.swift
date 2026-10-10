import Foundation
import SwiftData

/// One place's conversation with AI as it is kept, and synced through iCloud with the words: the wall's, or a word's
/// (`Chats`). The messages go as one piece of JSON, as the whole conversation is written at once.
@Model
final class Conversation {
    /// "wall", or the word's id.
    var key: String = ""
    /// JSON-encoded `Chat`.
    var data: Data?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(key: String) {
        self.key = key
    }
}
