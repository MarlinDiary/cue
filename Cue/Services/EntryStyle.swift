import Foundation

/// The house style of an entry, applied in code as well as asked of AI, so every page reads the same whatever the
/// model writes: English definitions set as a learner's dictionary sets them, and Chinese with full-width
/// punctuation, 「」 for quotes and a space between Chinese and English.
enum EntryStyle {
    /// Lowercase first word (unless it is a name or an abbreviation) and no full stop: "a place where water falls".
    static func definition(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("."), !text.hasSuffix(".."), !text.hasSuffix("etc.") { text.removeLast() }
        // Only the words a definition ordinarily opens with are lowercased: "A place…" and "To travel…", never
        // "London…" or "UK…".
        let firstWord = String(text.prefix { $0.isLetter })
        if let first = firstWord.first, first.isUppercase, openers.contains(firstWord.lowercased()) {
            text = first.lowercased() + text.dropFirst()
        }
        return text
    }

    /// The words a learner's-dictionary definition opens with.
    private static let openers: Set<String> = [
        "a", "an", "the", "to", "someone", "something", "somebody", "somewhere", "used", "having", "not", "in", "on",
        "at", "of", "very", "being", "if", "when", "with", "without", "able", "relating", "done", "made", "likely",
        "feeling", "showing", "causing", "giving", "making", "becoming", "extremely", "slightly", "completely", "full",
        "one", "any", "no", "all", "more", "most", "so", "too", "very", "quite", "rather", "only", "for", "from", "by",
        "about", "because", "before", "after", "during", "while", "as", "like", "than", "that", "this", "these", "those",
        "it", "its", "there", "here", "what", "which", "who", "how", "where", "why",
    ]

    /// Chinese running text: full-width punctuation in the Chinese, 「」 for quotes, one space between Chinese and an
    /// English word or number, and no space beside full-width punctuation. English sentences inside keep their own
    /// punctuation.
    static func chinese(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return text }
        let rules: [(String, String)] = [
            // “…” and "…" become 「…」.
            (#"[“"]([^“”"]*)[”"]"#, "「$1」"),
            // Brackets around Chinese, or right after it, are full-width.
            (#"\(([^()]*\p{Han}[^()]*)\)"#, "（$1）"),
            (#"(?<=[\p{Han}」》）])\s*\(([^()]*)\)"#, "（$1）"),
            // Punctuation after a Chinese character is Chinese punctuation.
            (#"(?<=[\p{Han}」》）])\s*,"#, "，"),
            (#"(?<=[\p{Han}」》）])\s*:"#, "："),
            (#"(?<=[\p{Han}」》）])\s*;"#, "；"),
            (#"(?<=[\p{Han}」》）])\s*\?"#, "？"),
            (#"(?<=[\p{Han}」》）])\s*!"#, "！"),
            (#"(?<=[\p{Han}」》）])\.(?=\s|$|\p{Han})"#, "。"),
            // A comma, colon or semicolon between an English word and Chinese belongs to the Chinese sentence.
            (#"(?<=[A-Za-z0-9])\s*,\s*(?=\p{Han})"#, "，"),
            (#"(?<=[A-Za-z0-9])\s*:\s*(?=\p{Han})"#, "："),
            (#"(?<=[A-Za-z0-9])\s*;\s*(?=\p{Han})"#, "；"),
            // One space between Chinese and English words or numbers.
            (#"(\p{Han})([A-Za-z0-9])"#, "$1 $2"),
            (#"([A-Za-z0-9])(\p{Han})"#, "$1 $2"),
            // A full stop after a single English word ends the Chinese sentence: "多处瀑布说 waterfalls。". After an
            // English sentence it stays that sentence's own.
            (#"(?<=\p{Han} )([A-Za-z][A-Za-z'’\-]*)\.(?=\s|$)"#, "$1。"),
            // No space beside full-width punctuation, and never two spaces.
            (#"\s+([，。：；？！）」』》、])"#, "$1"),
            (#"([，。：；？！（「『《、）」』》])\s+"#, "$1"),
            (#" {2,}"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// A short Chinese meaning, as in senses and collocations: house style, with nothing closing it.
    static func meaning(_ text: String) -> String {
        var text = chinese(text)
        while let last = text.last, "。；，、.".contains(last) { text.removeLast() }
        return text
    }

    /// Whether a headword is a sentence, said as a whole ("Where's the toilet?", "I'm lost."), rather than a word or a
    /// phrase ("change seats", "New Zealand"): it ends as a sentence does, or it starts with a capital and runs to more
    /// than one word, unless its card line labels it a word ("n. 新西兰").
    static func isSentence(_ headword: String, summary: String? = nil) -> Bool {
        let text = headword.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'“”‘’")))
        if let last = text.last, ".?!".contains(last) { return true }
        if let summary, summary.range(of: #"^(n|v|adj|adv|prep|conj|pron|int|num|det|aux|abbr)\.\s"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return text.first?.isUppercase == true && text.contains(" ")
    }

    /// Whether a headword is one word ("ubiquitous", "well-known") rather than a phrase or a sentence.
    static func isSingleWord(_ headword: String) -> Bool {
        !headword.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isWhitespace)
    }

    /// The page's pronunciation line: a single word's IPA ("/ˈtɔɪlət/"), and none for a phrase or a sentence, whose
    /// headword reads aloud when tapped instead (user, 2026-10-06, for sentences: "句的音标干脆不要了", after its hardest
    /// word's IPA alone had been tried; 2026-10-07, for phrases too: "去掉音标那一行").
    static func pronunciation(ipa: String?, headword: String?) -> String? {
        guard let headword, isSingleWord(headword), let ipa, !ipa.isEmpty else { return nil }
        return "/\(ipa)/"
    }

    /// A headword or request as compared, to find a card already on the wall: without case, surrounding space, or the
    /// punctuation that closes a sentence ("I'm lost" finds "I'm lost.").
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".?!。？！"))).lowercased()
    }
}

extension WordEntry {
    /// This entry in the house style (see `EntryStyle`), for its headword. The punctuation that closes a sentence
    /// comes from the prompt, never from here (user, 2026-10-06: "加标点不该是我们后期加的吧，应该是提示词要求的"):
    /// a sentence's Chinese keeps the mark AI closed it with, and so do the lines of its exchange and another way to
    /// say it that ends as a sentence; a word's or phrase's meaning has nothing closing it, as the prompt also asks.
    func styled(headword: String? = nil) -> WordEntry {
        var entry = self
        let sentence = headword.map { EntryStyle.isSentence($0, summary: summary) } ?? false
        entry.parts = parts.map { part in
            var part = part
            part.senses = part.senses.map { sense in
                var sense = sense
                sense.chinese = sentence ? EntryStyle.chinese(sense.chinese) : EntryStyle.meaning(sense.chinese)
                sense.english = sense.english.map(EntryStyle.definition)
                sense.example = sense.example?.trimmingCharacters(in: .whitespacesAndNewlines)
                sense.exampleChinese = sense.exampleChinese.map(EntryStyle.chinese)
                return sense
            }
            return part
        }
        entry.exchange = exchange?.map { line in
            .init(english: line.english.trimmingCharacters(in: .whitespacesAndNewlines), chinese: EntryStyle.chinese(line.chinese))
        }
        entry.collocations = collocations?.map { item in
            let phrase = item.phrase.trimmingCharacters(in: .whitespaces)
            let closes = phrase.last.map { ".?!".contains($0) } ?? false
            return .init(phrase: phrase, chinese: closes ? EntryStyle.chinese(item.chinese) : EntryStyle.meaning(item.chinese))
        }
        entry.note = note.map(EntryStyle.chinese)
        entry.etymology = etymology.map(EntryStyle.chinese)
        entry.question = question.map(EntryStyle.chinese)
        entry.pictureIdea = pictureIdea?.trimmingCharacters(in: .whitespacesAndNewlines)
        return entry
    }
}
