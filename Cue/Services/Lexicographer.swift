import SwiftData
import SwiftUI

/// Fills in a word's entry, written by AI in the background, so it keeps going after the user leaves the page. AI also
/// decides the headword from whatever the user typed: a word, Chinese, a request in their own words, a misspelling.
@Observable
final class Lexicographer {
    static let shared = Lexicographer()

    private(set) var writing: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]
    /// What has arrived of each entry being written, while it streams in, and that much of it as an entry.
    private(set) var drafts: [UUID: EntryDraft] = [:]
    private var draftEntries: [UUID: WordEntry] = [:]
    /// A new card whose headword turned out to be a word the wall has a card for: the wall turns it into that card.
    var merge: Merge?

    struct Merge: Equatable {
        var new: UUID
        var existing: UUID
    }

    /// New words the wall is still asking about (`DuplicateCheck`) before their writing starts: their cards wait as
    /// cards being written do meanwhile.
    private var expected: Set<UUID> = []

    func isWriting(_ word: Word) -> Bool { writing.contains(word.id) || expected.contains(word.id) }
    func failure(for word: Word) -> String? { failures[word.id] }
    func draft(for word: Word) -> EntryDraft? { drafts[word.id] }

    /// The entry to show while one streams in: the draft, once it has a sense to show. A word that already has an AI
    /// entry keeps it until the new one is complete, rather than shrinking back to the first sense.
    func entryInProgress(for word: Word) -> WordEntry? {
        // A new word's entry as it streams in; a word being rewritten keeps showing its old entry until the new one is
        // done.
        guard arrivals[word.id] != nil || word.entry?.origin != .ai else { return nil }
        return draftEntries[word.id]
    }

    /// A new word whose writing starts as soon as the wall knows it isn't a card it has already: its card waits as one
    /// being written does meanwhile, the user's words in its middle.
    func expect(_ word: Word) {
        expected.insert(word.id)
        arrivals[word.id] = Arrivals()
    }

    /// Keeps `typed` as what a new word's card shows while it waits, whatever comes to be asked for it: the card that
    /// went up for several things typed at once, asked now for the first of them (`HomeView.add`).
    func keepShowing(_ typed: String, for word: Word) {
        placeholders[word.id] = typed
    }

    /// `rewrite` asks for a new AI entry even when the word already has a final one.
    func write(_ word: Word, rewrite: Bool = false) {
        guard let context = word.modelContext else { return }
        let needed = rewrite || !(word.entry?.isFinal ?? false)
        guard needed, AIAccess.isAvailable, !writing.contains(word.id) else { return }

        let id = word.id, text = word.text
        let resolving = word.awaitsHeadword
        expected.remove(id)
        // Rewriting a word the user reached by asking: keep the headword, and answer what they first asked.
        let asked = word.request.flatMap { EntryStyle.key($0) == EntryStyle.key(text) ? nil : $0 }
        let input = resolving ? word.request ?? text : asked.map { "\(text) — original question: \($0)" } ?? text
        writing.insert(id)
        failures[id] = nil
        arrivals[id] = resolving ? Arrivals() : nil
        Task {
            // The entry goes on being written for a while if the user leaves the app.
            let keepAlive = KeepAlive("Writing an entry")
            defer {
                keepAlive.end()
                writing.remove(id)
                draftEntries[id] = nil
                // A new word's draft stays until its picture is in: the card shows the headword from it meanwhile.
                if arrivals[id] == nil { drafts[id] = nil }
            }
            do {
                // The picture idea comes early in the entry: the picture starts then, a few seconds in, while the
                // rest is still being written.
                var pictureStarted = false
                var headwordChecked = false
                var (headword, entry) = try await EntryGenerator.entry(for: input, fresh: rewrite) { draft in
                    // A request whose headword is a card the wall already has turns into that card as soon as the
                    // headword is in, before anything more is written or drawn for it (user, 2026-10-07: it went only
                    // once the whole entry was written, several seconds later, the new card filling in meanwhile).
                    if resolving, !headwordChecked, let headword = draft.headword, !headword.isEmpty {
                        headwordChecked = true
                        if let existing = card(matching: headword, besides: id, in: context) {
                            merge = Merge(new: id, existing: existing)
                            return false
                        }
                    }
                    draftEntries[id] = draft.entry
                    drafts[id] = draft
                    if resolving { note(draft, for: id) }
                    if !pictureStarted, let idea = draft.pictureIdea {
                        pictureStarted = true
                        startPicture(for: id, idea: idea, in: context)
                    }
                    return true
                }
                entry.origin = .ai
                // Look the word up again: it may have been deleted while the entry was being written.
                let all = (try? context.fetch(FetchDescriptor<Word>())) ?? []
                guard let word = all.first(where: { $0.id == id }) else { return }
                if resolving, !headword.isEmpty { word.text = headword }
                word.entry = entry
                try? context.save()
                if !pictureStarted, word.imageData == nil { Illustrator.shared.draw(word) }
                // The headword's voice, kept before anyone taps it.
                Speech.shared.prepare(word.text)
            } catch is CancellationError {
                // Stopped as a card the wall already has: the wall turns this one into it, still looking as it did
                // until then.
            } catch {
                failures[id] = "Couldn’t write a full entry: \(error.localizedDescription)"
                arrivals[id] = nil
            }
        }
    }

    // MARK: How a new word's card fills in

    /// When each piece of a new word's entry arrived, so the card can bring them in one after another.
    struct Arrivals: Equatable {
        var headword, phonetic, summary, idea: Date?
    }

    /// The pieces of a new word's entry that its card and page bring in, with when each arrived, and the user's own
    /// words, which hold the middle of the card until the headword comes: nil once the word is written and its picture
    /// is in.
    struct Generation {
        var headword, phonetic, summary, idea: String?
        var placeholder: String
        var arrivals: Arrivals
        /// Twice the usual for a card coming in again (`replay`).
        var speed = 1.0

        /// Whether the headword is the user's own words: they then rise into its place rather than giving way to it.
        var same: Bool { headword.map { EntryStyle.key($0) == EntryStyle.key(placeholder) } ?? false }

        private var headwordField: TypingSchedule.Field {
            .init(text: headword, arrival: arrivals.headword,
                  lead: same ? GenerationPlaceholder.rise : GenerationPlaceholder.overlap, instant: same)
        }

        /// The card brings in the headword, its meaning and the picture's description, one after another.
        var cardSchedule: TypingSchedule {
            TypingSchedule([headwordField, .init(text: summary, arrival: arrivals.summary),
                            .init(text: idea, arrival: arrivals.idea)], speed: speed)
        }

        /// The page's pronunciation line as it will read: none for a phrase or a sentence.
        var pronunciation: String? { EntryStyle.pronunciation(ipa: phonetic, headword: headword) }

        /// The page brings in the headword, its pronunciation and the picture's description.
        var pageSchedule: TypingSchedule {
            TypingSchedule([headwordField, .init(text: phonetic.map { _ in pronunciation ?? "" }, arrival: arrivals.phonetic),
                            .init(text: idea, arrival: arrivals.idea)], speed: speed)
        }
    }

    private var arrivals: [UUID: Arrivals] = [:]

    /// What a card coming in again (`replay`) shows as typed while it waits, the words it went up with, and how fast
    /// it comes in.
    private var placeholders: [UUID: String] = [:]
    private var speeds: [UUID: Double] = [:]

    func generation(for word: Word) -> Generation? {
        guard let arrivals = arrivals[word.id] else { return nil }
        let draft = drafts[word.id]
        var placeholder = placeholders[word.id] ?? word.request ?? word.text
        #if DEBUG
        if let typed = rehearsedRequests[word.id] { placeholder = typed }
        #endif
        return Generation(headword: draft?.headword, phonetic: draft?.phoneticUS ?? (arrivals.phonetic == nil ? nil : ""),
                          summary: draft?.summary ?? word.entry?.summary,
                          idea: draft?.pictureIdea ?? word.entry?.pictureIdea,
                          placeholder: placeholder, arrivals: arrivals, speed: speeds[word.id] ?? 1)
    }

    /// Once the word's picture is in and settled, nothing comes in any more.
    func forgetGeneration(for id: UUID) {
        expected.remove(id)
        arrivals[id] = nil
        drafts[id] = nil
        placeholders[id] = nil
        speeds[id] = nil
        #if DEBUG
        rehearsedRequests[id] = nil
        #endif
    }

    /// Brings in a word that has all of it already as a new word comes in, quickly: the headword, its meaning and the
    /// picture's description come in one after another on its card and page, twice as fast as they usually do, and the
    /// picture forms from the description as soon as it is in; three or four seconds instead of the half minute
    /// writing and drawing take. For a card that turned into one the wall had (`HomeView.become`): it comes in as any card does,
    /// rather than all of it appearing at once (user, 2026-10-07: "还是要有这个…文字出现的动画呀，然后提示词变成图片的
    /// 动画呀，这些的话都可以快速地走一轮"). `typed` is what its waiting words were.
    func replay(_ word: Word, typed: String) {
        guard let entry = word.entry else { return }
        let id = word.id
        expected.remove(id)
        writing.insert(id)
        placeholders[id] = typed
        speeds[id] = 2
        if arrivals[id] == nil { arrivals[id] = Arrivals() }
        // Everything arrives at once, a moment from now; the card's schedule then brings the pieces in one by one,
        // and the picture comes when the last is in.
        let start = Date.now.addingTimeInterval(0.25)
        let planned = Generation(headword: word.text, phonetic: entry.phoneticUS ?? "", summary: entry.summary,
                                 idea: entry.pictureIdea, placeholder: typed,
                                 arrivals: Arrivals(headword: start, phonetic: start, summary: start, idea: start),
                                 speed: 2)
        let done = (planned.cardSchedule.end(2) ?? start).addingTimeInterval(0.3)
        if word.imageData != nil { Illustrator.shared.replay(word, at: done) }
        Task {
            try? await Task.sleep(for: .seconds(0.25))
            var draft = EntryDraft(headword: word.text)
            draft.phoneticUS = entry.phoneticUS
            draft.summary = entry.summary
            draft.pictureIdea = entry.pictureIdea
            drafts[id] = draft
            note(draft, for: id)
            try? await Task.sleep(for: .seconds(max(done.timeIntervalSinceNow, 0)))
            writing.remove(id)
            // A picture forgets the coming in once it has formed; with none, it is over now.
            if word.imageData == nil { forgetGeneration(for: id) }
        }
    }

    #if DEBUG
    /// What a rehearsal plays as typed, in place of the word's own request.
    private var rehearsedRequests: [UUID: String] = [:]

    /// Plays a new word's writing for a stored word, for free: nothing but the user's words for a while, then the
    /// headword, pronunciation, meaning and picture idea arrive as a real entry's do, and the picture is "drawn".
    /// Launch with `-rehearseEntry <word>`, and `-rehearseAs <text>` to play it as if that had been typed. Nothing
    /// is saved.
    func rehearse(_ word: Word, as typed: String? = nil) {
        guard let entry = word.entry, !writing.contains(word.id) else { return }
        let id = word.id
        writing.insert(id)
        rehearsedRequests[id] = typed
        arrivals[id] = Arrivals()
        Illustrator.shared.rehearse(word, ideaAfter: .seconds(4.6), taking: .seconds(8))
        Task {
            try? await Task.sleep(for: .seconds(3))
            var draft = EntryDraft(headword: word.text)
            drafts[id] = draft
            note(draft, for: id)
            try? await Task.sleep(for: .seconds(0.4))
            draft.phoneticUS = entry.phoneticUS
            draft.summary = entry.summary
            drafts[id] = draft
            note(draft, for: id)
            try? await Task.sleep(for: .seconds(1.2))
            draft.pictureIdea = entry.pictureIdea
            drafts[id] = draft
            note(draft, for: id)
            // The senses, or a sentence's exchange, stream in after the idea, the first one first.
            try? await Task.sleep(for: .seconds(1))
            var first = entry
            first.parts = entry.parts.prefix(1).map { WordEntry.Part(pos: $0.pos, senses: Array($0.senses.prefix(1))) }
            first.exchange = entry.exchange.map { Array($0.prefix(1)) }
            first.collocations = nil
            first.note = nil
            first.etymology = nil
            first.question = nil
            draftEntries[id] = first
            try? await Task.sleep(for: .seconds(1))
            draftEntries[id] = entry
            try? await Task.sleep(for: .seconds(0.5))
            draftEntries[id] = nil
            writing.remove(id)
        }
    }
    #endif

    private func note(_ draft: EntryDraft, for id: UUID) {
        guard var arrivals = arrivals[id] else { return }
        if arrivals.headword == nil, let headword = draft.headword, !headword.isEmpty { arrivals.headword = .now }
        // A headword without a pronunciation still lets the page go on to the next piece once the meaning is in.
        if arrivals.phonetic == nil, draft.phoneticUS?.isEmpty == false || draft.summary != nil { arrivals.phonetic = .now }
        if arrivals.summary == nil, let summary = draft.summary, !summary.isEmpty { arrivals.summary = .now }
        if arrivals.idea == nil, let idea = draft.pictureIdea, !idea.isEmpty { arrivals.idea = .now }
        self.arrivals[id] = arrivals
    }

    /// Draws the first picture as soon as its idea is in. A word that already has a picture keeps it (a rewrite never
    /// redraws by itself). A request whose headword is a card the wall already has never gets this far: it stops at its
    /// headword.
    private func startPicture(for id: UUID, idea: String, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        guard let word = all.first(where: { $0.id == id }), word.imageData == nil else { return }
        Illustrator.shared.draw(word, idea: idea)
    }

    /// A card the wall already has for this headword, other than the word being written.
    private func card(matching headword: String, besides id: UUID, in context: ModelContext) -> UUID? {
        let all = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        return all.first { $0.id != id && $0.matches(headword) }?.id
    }
}
