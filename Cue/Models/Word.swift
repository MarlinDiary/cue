import Foundation
import SwiftData

/// A saved word.
@Model
final class Word {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date.now
    /// Pinning was dropped on 2026-10-06; the column stays so older stores still open.
    var isPinned: Bool = false
    /// Transparent PNG of the word's illustration.
    @Attribute(.externalStorage) var imageData: Data?
    /// JSON-encoded `WordEntry`, nil until the word has a dictionary entry.
    var entryData: Data?
    /// The sentence the word was met in, and where.
    var sentence: String = ""
    var source: String = ""
    /// What the user typed: an English word, Chinese, a request in their own words, or a misspelling. AI turns it into
    /// the English word or expression that becomes `text`; until then the card shows nothing but the cursor.
    var request: String?
    /// JSON-encoded `Recall.State`: how firmly the word is remembered, nil until it is first reviewed.
    var recallData: Data?
    /// Left out of review by the user, from review's menu (user, 2026-10-09: "有些卡片…never appear again"): the card
    /// stays on the wall, and its page puts it back.
    var hiddenFromReview: Bool = false
    /// JSON-encoded `[WordNote]`: what the user asked about the word in its conversation and chose to keep on its page,
    /// each with the gist of its answer.
    var notesData: Data?

    init(text: String, entry: WordEntry? = nil, sentence: String = "", source: String = "", createdAt: Date = .now) {
        self.text = text
        self.entryData = entry.flatMap { try? JSONEncoder().encode($0) }
        self.sentence = sentence
        self.source = source
        self.createdAt = createdAt
    }

    var entry: WordEntry? {
        get { entryData.flatMap { try? JSONDecoder().decode(WordEntry.self, from: $0) } }
        set { entryData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var recall: Recall.State? {
        get { recallData.flatMap { try? JSONDecoder().decode(Recall.State.self, from: $0) } }
        set { recallData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// What the user kept on the page from the word's conversation, oldest first.
    var notes: [WordNote] {
        get { notesData.flatMap { try? JSONDecoder().decode([WordNote].self, from: $0) } ?? [] }
        set { notesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Still showing the user's own words until AI decides the English headword.
    var awaitsHeadword: Bool { request != nil && entryData == nil }

    /// What review asks for, by why the word was saved (user, 2026-10-07: "有时候是不知道某个东西的英文表达方式，有时候是
    /// 这个英文单词我不认识…这是两种东西"). When the user asked something (in Chinese, or "how do I say…" in English),
    /// it was something they didn't know how to say: review shows their own words and asks the English. When they
    /// typed the word itself, in whatever form or spelling, it was a word they didn't know: review shows it and asks
    /// its meaning. AI tells the two apart as it writes the entry, keeping what was asked as `question`; a misspelt
    /// word, which the prompt also records there, marked "（拼写有误）", was typed as itself. (Telling them apart by the
    /// language typed was tried first: "how to say I am running late" then counted as a word not known.)
    var asksForEnglish: Bool {
        guard let question = entry?.question, !question.isEmpty else { return false }
        return !question.hasSuffix("（拼写有误）")
    }

    /// The card's Chinese line ("n. 母牛", "v. 通勤  n. 通勤路程", "这个多少钱？") in three: the part-of-speech label before
    /// its first meaning, the first meaning, and the rest. A card asking for the English asks with that meaning, never
    /// with what the user typed (user, 2026-10-07, on 🐮 typed for "cow": "我觉得是要显示母牛的"), and as the answer
    /// shows, the meaning moves into its place in the line.
    var summaryParts: (label: String, meaning: String, rest: String) {
        let summary = entry?.summary ?? ""
        var label = "", rest = ""
        var meaning = summary[...]
        if let range = summary.range(of: #"^(n|v|adj|adv|prep|conj|pron|int|num|det|aux|abbr|phr)\.\s*"#,
                                     options: .regularExpression) {
            label = String(summary[range])
            meaning = summary[range.upperBound...]
        }
        if let gap = meaning.range(of: "  ") {
            rest = String(meaning[gap.lowerBound...])
            meaning = meaning[..<gap.lowerBound]
        }
        return (label, String(meaning), rest)
    }

    /// Whether typing `input` should find this card rather than add a new one: it is the card's English, what was
    /// first typed for it, or one of its meanings in Chinese, word for word (user, 2026-10-07: "我搜一个完全能匹配中文、
    /// 完全能匹配英文的东西，那干嘛要新建这个卡片").
    func matches(_ input: String) -> Bool {
        let key = EntryStyle.key(input)
        return EntryStyle.key(text) == key || request.map(EntryStyle.key) == key
            || chineseMeanings.contains { EntryStyle.key($0) == key }
    }

    /// The meanings the card gives in Chinese: each on its Chinese line ("adj. 坦率的；直言不讳的" gives both, "v. 通勤
    /// n. 通勤路程" both; a sentence's line is the one meaning), and each sense's. Never split at a comma, which would
    /// take a sentence's first clause for a meaning.
    var chineseMeanings: [String] {
        guard let entry else { return [] }
        var meanings: [String] = []
        for group in entry.summary.components(separatedBy: "  ") {
            let meaning = group.replacingOccurrences(of: #"^(n|v|adj|adv|prep|conj|pron|int|num|det|aux|abbr|phr)\.\s*"#,
                                                     with: "", options: .regularExpression)
            meanings += meaning.components(separatedBy: CharacterSet(charactersIn: "；;"))
        }
        meanings += entry.parts.flatMap { $0.senses.map(\.chinese) }
        return meanings.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// A dictionary entry, laid out the way a learner's dictionary reads.
struct WordEntry: Codable, Hashable {
    var phoneticUK: String?
    var phoneticUS: String?
    /// One-line Chinese summary for the card, e.g. "n. 机缘巧合".
    var summary: String
    /// A word's or phrase's senses; none for a sentence, which has an exchange instead.
    var parts: [Part]
    /// For a sentence: the two lines it is typically said in, one said and one in reply, the sentence itself one of
    /// them, in place of a definition and an example (user, 2026-10-07: "释义和例句换成一问一答").
    var exchange: [Line]?
    var etymology: String?
    /// When the word sounds natural (register, situations) and a typical mistake, in Chinese.
    var note: String?
    /// Common collocations and set phrases, most useful first.
    var collocations: [Collocation]?
    /// When the user typed Chinese or a question: AI's clean rewording of what they wanted to know, kept as a record of
    /// it; when they misspelt the word: what they typed, marked as misspelt. The entry itself is the answer.
    var question: String?
    /// One sentence saying what the word's picture shows: one moment, never a change. Written with the entry, since the
    /// writer knows the word; the image model alone, given a bare abstract phrase, piles up symbols and arrows.
    var pictureIdea: String?
    /// ECDICT exam tags, e.g. ["cet4", "ielts"]. Kept, but not shown.
    /// Where the entry came from. Nil for the hand-written samples.
    var origin: Origin?
    /// The shape of AI entries this one was written to; older AI entries get rewritten when their page opens.
    var version: Int?

    /// 3: nothing repeated across the page, and one house style. 4: a picture idea.
    static let currentVersion = 4

    enum Origin: String, Codable {
        /// The short entry of the offline dictionary the app used to bundle (dropped 2026-10-06); older stores may
        /// still hold one, and it is rewritten by AI like any entry that isn't final.
        case dictionary
        case ai
    }

    /// True once nothing better is coming: a hand-written entry, or an AI one of the current shape.
    var isFinal: Bool {
        switch origin {
        case .dictionary: false
        case .ai: (version ?? 1) >= Self.currentVersion
        case nil: true
        }
    }

    struct Collocation: Codable, Hashable {
        var phrase: String
        var chinese: String
    }

    /// One line of an exchange. Its Chinese is empty only while the line is still streaming in.
    struct Line: Codable, Hashable {
        var english: String
        var chinese: String
    }

    struct Part: Codable, Hashable {
        /// noun, verb, adjective…
        var pos: String
        var senses: [Sense]
    }

    struct Sense: Codable, Hashable {
        /// One natural Chinese equivalent: a different meaning is a different sense.
        var chinese: String
        /// Missing in entries from the offline dictionary, which only has Chinese.
        var english: String?
        var example: String?
        var exampleChinese: String?
    }
}

extension WordEntry.Part {
    var label: String {
        pos
    }
}

/// A question asked about a word in its conversation, put as it was meant, and the gist of its answer: what the user
/// can keep on the word's page, under You Asked (user, 2026-10-18: "把我们的这个Q&A…加入到卡片里面，形成永久性的东西…
/// Q…是formatted之后的…A…in summary的"). Offered by AI under an answer worth keeping (`NoteClient`), never under a
/// greeting.
nonisolated struct WordNote: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var question: String
    var answer: String
}

extension WordEntry {
    /// English names for ECDICT's exam tags.
    static func examName(_ tag: String) -> String {
        switch tag {
        case "zk": "Zhongkao"
        case "gk": "Gaokao"
        case "cet4": "CET-4"
        case "cet6": "CET-6"
        case "ky": "Kaoyan"
        case "ielts": "IELTS"
        case "toefl": "TOEFL"
        case "gre": "GRE"
        default: tag.uppercased()
        }
    }
}
