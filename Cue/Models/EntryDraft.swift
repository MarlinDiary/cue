import Foundation

/// What has arrived of an entry while it streams in. Every field is optional, and a field is only here once it is
/// complete (see `PartialJSON`).
struct EntryDraft: Decodable, Equatable {
    struct Sense: Decodable, Equatable {
        var chinese, english, example, exampleChinese: String?
    }

    struct Part: Decodable, Equatable {
        var pos: String?
        var senses: [Sense]?
    }

    struct Collocation: Decodable, Equatable {
        var phrase, chinese: String?
    }

    struct Line: Decodable, Equatable {
        var english, chinese: String?
    }

    var headword, pictureIdea, phoneticUS, summary, note, etymology, question: String?
    var parts: [Part]?
    var exchange: [Line]?
    var collocations: [Collocation]?

    /// What can already be shown as an entry: nothing until one sense of one part of speech is in, or for a sentence,
    /// the first line of its exchange.
    var entry: WordEntry? {
        let parts = (parts ?? []).compactMap { part -> WordEntry.Part? in
            guard let pos = part.pos else { return nil }
            let senses = (part.senses ?? []).compactMap { sense in
                sense.chinese.map {
                    WordEntry.Sense(chinese: $0, english: sense.english, example: sense.example,
                                    exampleChinese: sense.exampleChinese)
                }
            }
            return senses.isEmpty ? nil : WordEntry.Part(pos: pos, senses: senses)
        }
        let exchange = (exchange ?? []).compactMap { line in
            line.english.map { WordEntry.Line(english: $0, chinese: line.chinese ?? "") }
        }
        guard !parts.isEmpty || !exchange.isEmpty else { return nil }
        let collocations = (collocations ?? []).compactMap { item in
            item.phrase.flatMap { phrase in item.chinese.map { WordEntry.Collocation(phrase: phrase, chinese: $0) } }
        }
        return WordEntry(
            phoneticUK: nil, phoneticUS: phoneticUS, summary: summary ?? "", parts: parts,
            exchange: exchange.isEmpty ? nil : exchange, etymology: etymology, note: note,
            collocations: collocations.isEmpty ? nil : collocations, question: question, pictureIdea: pictureIdea,
            origin: .ai
        ).styled(headword: headword)
    }
}
