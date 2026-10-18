import SwiftUI
import SwiftData

/// A word's page, set like a dictionary entry: one continuous column, no cards. Its bars, which stay put as the user
/// goes from word to word, are `WordPager`'s.
struct WordPage: View {
    @Bindable var word: Word
    /// Told whether the big headword has scrolled up under the bar, which then shows the word instead.
    var onTitleHidden: (Bool) -> Void = { _ in }
    @Environment(\.modelContext) private var modelContext

    private let speech = Speech.shared
    private let illustrator = Illustrator.shared
    private let lexicographer = Lexicographer.shared
    /// The headword, as what was tapped while it is read.
    @State private var headwordReader = UUID()
    /// The system dictionary, offered when the word has no entry.
    @State private var showingSystemDictionary = false
    /// What stands between the page and AI, once the user asks to get past it.
    @State private var gate: AIGate?
    /// The colour of the word's picture, for what lights up while it is read aloud.
    @State private var pictureTint: Color?
    /// While a new word is written, the headword's frame, for the user's own words to rise into when they turn out to
    /// be it, and the picture's room, in the middle of which they wait meanwhile: the middle as it was before the
    /// headword came, so they don't jump when a two-line headword pushes the room down as they go.
    @State private var titleFrame: CGRect = .zero
    @State private var room: CGRect = .zero
    @State private var waitingSpot: CGPoint?

    /// The entry, or as much of a new one as has streamed in: senses appear one by one while AI writes.
    private var entry: WordEntry? {
        if let streaming = lexicographer.entryInProgress(for: word) { return streaming }
        // A new word's page shows only what has streamed in, until its entry is written.
        if generation != nil, lexicographer.isWriting(word) { return nil }
        return word.entry
    }

    /// A new word's headword, coming in as AI sends it, with the picture's description after it; nil once it is written.
    private var generation: Lexicographer.Generation? { lexicographer.generation(for: word) }

    /// The word, or while AI is still deciding it, its English headword as it comes in (a space holds the line).
    private var headwordText: String { generation.map { $0.headword ?? " " } ?? word.text }

    /// For the bar: the word, or until AI has decided it, the user's own words.
    private var title: String { generation?.headword ?? word.text }

    /// Whether the user's own words still hold the page: until the headword is in.
    private var holding: Bool {
        generation.map { $0.headword == nil || !$0.pageSchedule.isDone(0, at: .now) } ?? false
    }

    /// Whether the user's own words stand in for the headword: they are it, and have yet to hand it over.
    private var standingIn: Bool { holding && generation?.same == true }

    /// Whether the headword is a sentence: AI then gives other ways to say it rather than phrases built on it.
    private var isSentence: Bool {
        EntryStyle.isSentence(title, summary: generation?.summary ?? entry?.summary)
    }

    /// Whether the headword is a phrase or a sentence rather than one word: it then has no pronunciation line, and
    /// reads aloud when tapped.
    private var isMultiWord: Bool { !EntryStyle.isSingleWord(title) }

    /// The IPA as soon as it has streamed in, before the first sense makes an entry of the draft; none for a phrase or
    /// a sentence.
    private var pronunciationLine: String? {
        if let generation { return generation.pronunciation }
        return EntryStyle.pronunciation(ipa: entry?.phoneticUS, headword: word.text)
    }

    /// Whether to say an entry is being updated: only for a word that already has one (a new word's typing says
    /// enough), and not once its first senses are already streaming onto the page.
    private var showsEntryStatus: Bool {
        guard lexicographer.entryInProgress(for: word) == nil, generation == nil else { return false }
        return (lexicographer.isWriting(word) && word.entry != nil) || lexicographer.failure(for: word) != nil
            || !(word.entry?.isFinal ?? true)
    }

    /// What the user wanted to know when they typed Chinese or a question, as AI reworded it, or what they typed when
    /// they misspelt the word, marked as misspelt (user, 2026-10-07: "拼错的也写在youasked呗"). Nothing for a word typed
    /// as itself, in whatever form, and nothing while AI is still writing: the section never shows empty.
    private var askedQuestion: String? {
        guard let question = entry?.question, !question.isEmpty else { return nil }
        return question
    }

    var body: some View {
        ScrollView {
            // The same order as the card (word, then picture), so the zoom out of the card lines the two up.
            VStack(alignment: .leading, spacing: 0) {
                headword
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY < 110 } action: { hidden in
                        onTitleHidden(hidden)
                    }
                if entry != nil, showsEntryStatus { entryStatus.padding(.top, 12).transition(.blurReplace) }
                illustration
                if let entry {
                    VStack(alignment: .leading, spacing: 30) {
                        // By position, so a part keeps its place while its senses stream in.
                        ForEach(Array(entry.parts.enumerated()), id: \.offset) { _, part in
                            partSection(part).transition(.blurReplace)
                        }
                        if let exchange = entry.exchange, !exchange.isEmpty {
                            exchangeSection(exchange)
                        }
                    }
                    .padding(.top, 34)
                    if let phrases = entry.collocations, !phrases.isEmpty {
                        // For a phrase or a sentence AI gives other ways to say it rather than phrases built on it, and
                        // the heading says so (user, 2026-10-06: "如果我问的是句子，phrases还是phrases么？").
                        let alternatives = isSentence || entry.summary.lowercased().hasPrefix("phr.")
                        section(alternatives ? "Other Ways to Say It" : "Phrases") { phraseList(phrases) }
                    }
                    if let note = entry.note {
                        section("Usage") { MixedText(note) }
                    }
                    if let etymology = entry.etymology {
                        section("Origin") { MixedText(etymology) }
                    }
                    // Last: a record of what was asked as the word was added, only the question, since the whole page is
                    // the answer; then what the user kept from the word's conversation, each question with the gist of
                    // its answer, oldest first.
                    let notes = word.notes
                    if askedQuestion != nil || !notes.isEmpty {
                        section("You Asked") {
                            VStack(alignment: .leading, spacing: 24) {
                                if let askedQuestion {
                                    Text(askedQuestion).font(.body).lineSpacing(4).foregroundStyle(.secondary)
                                }
                                ForEach(notes) { note in
                                    noteView(note)
                                        // Deleted from its menu at once, as a card is, its lifted copy dissolving where
                                        // it stands: the copy is its own view, as the source leaves in the action.
                                        .contextMenu {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                word.notes.removeAll { $0.id == note.id }
                                                try? modelContext.save()
                                            }
                                        } preview: {
                                            noteView(note)
                                                .padding(18)
                                                .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
                                                // Its whole height: offered its ideal size, the answer was cut short.
                                                .fixedSize(horizontal: false, vertical: true)
                                                .background(Color(.systemBackground))
                                        }
                                        // Its Delete all in red, as the system's are: in the picture's colour, which
                                        // the page tints with, its trash was brown.
                                        .tint(.red)
                                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                                }
                            }
                        }
                    }
                } else {
                    noEntry.transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named("page"))
            .overlay(alignment: .topLeading) {
                // The user's own words, in the middle of the picture's room until the headword comes.
                if let generation, room != .zero, holding {
                    GenerationPlaceholder(text: generation.placeholder,
                                          headword: generation.same ? generation.headword : nil, font: headwordFont,
                                          fontSize: 44, center: waitingSpot ?? CGPoint(x: room.midX, y: room.midY),
                                          width: room.width, slot: titleFrame, schedule: generation.pageSchedule,
                                          lines: 4)
                        .transition(.identity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .animation(.smooth(duration: 0.45), value: entry)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The caret and selection in the text's own colour without one: never the system's blue.
        .tint(pictureTint ?? .primary)
        .environment(\.readingColor, pictureTint)
        // Off the main thread: decoding the picture to find its colour took 11 ms on the Mac (so a frame or three on the
        // phone) in the middle of the card's zoom into the page.
        .task(id: word.imageData) {
            guard let data = word.imageData else { return pictureTint = nil }
            pictureTint = await Task.detached(priority: .userInitiated) { PictureTint.color(for: data) }.value
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingSystemDictionary) {
            SystemDictionaryView(term: word.text).ignoresSafeArea()
        }
        .sheet(item: $gate) { gate in
            AIGateSheet(gate: gate) {
                lexicographer.write(word)
                if word.imageData == nil { illustrator.draw(word) }
            }
        }
        .onAppear {
            lexicographer.write(word)
            if word.imageData == nil { illustrator.draw(word) }
            // The headword's voice, ready before the first tap (a written word's only: not the user's own words).
            if generation == nil, word.entry != nil { speech.prepare(word.text) }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var illustration: some View {
        if WordPicture.isShown(for: word) {
            // A fixed room, the card's scaled to the page, whatever the picture's shape and whether it is in yet, so
            // the page never moves under it.
            WordPicture(word: word, area: 52_900, maxWidth: 320, maxHeight: 265, schedule: generation?.pageSchedule)
                .frame(height: 265)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { frame in
                    room = frame
                    if generation != nil, generation?.headword == nil { waitingSpot = CGPoint(x: frame.midX, y: frame.midY) }
                }
                .padding(.top, 20)
        } else if !AIAccess.isAvailable {
            Group {
                if AIConsent.given {
                    Text("Add an OpenAI API key in Settings to draw pictures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Turn On AI", systemImage: "sparkles") { gate = .consent }
                        .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private let headwordFont = Font.system(size: 44, weight: .bold, design: .serif)

    private var headword: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The headword takes the lines it needs, at the top. (A two-line box with the headword on its bottom line
            // left a single word under a wide gap; nothing below is shown yet when a new word's length becomes known.)
            Group {
                if let generation, !generation.same {
                    TypedLine(text: headwordText, schedule: generation.pageSchedule, index: 0)
                } else {
                    // A phrase or a sentence reads aloud when tapped, lit while it is read, as the pronunciation line
                    // is for a word: there is no speaker icon (user, 2026-10-06: "不要喇叭的标识").
                    let reading = isMultiWord && speech.isReading(headwordReader)
                    Text(headwordText)
                        .textSelection(.enabled)
                        .foregroundStyle(reading ? Reading.lit(pictureTint) : AnyShapeStyle(.primary))
                        .animation(.reading(reading), value: reading)
                        .onTapGesture { if isMultiWord { speech.speak(word.text, from: headwordReader) } }
                }
            }
            .font(headwordFont)
            // A long sentence wraps rather than shrinks (user, 2026-10-06: "句子为啥不多写几行").
            .lineLimit(4)
            .minimumScaleFactor(0.6)
            // The user's own words stand in for the headword until they have risen into it.
            .opacity(standingIn ? 0 : 1)
            .transaction(value: standingIn) { $0.animation = nil }
            .background {
                if generation != nil {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { titleFrame = $0 }
                }
            }
            // The pronunciation's line is kept from the start, so nothing below moves when it comes in; for a new
            // word it comes in after the headword, word by word, as everything else does.
            // A phrase or a sentence has no such line, so its picture follows it directly.
            if !isMultiWord {
                ZStack(alignment: .leading) {
                    Text(" ").font(.body)
                    if let pronunciationLine {
                        pronunciation(pronunciationLine, schedule: generation?.pageSchedule)
                            .id(pronunciationLine)
                            .transition(.blurReplace)
                    }
                }
            }
        }
        .padding(.top, 12)
        .animation(generation == nil ? .smooth(duration: 0.45) : nil, value: pronunciationLine)
    }

    /// American IPA and voice (the user's choice, 2026-10-06; British had been used before as the standard closest to
    /// New Zealand English). Tapping the IPA says the word.
    private func pronunciation(_ line: String, schedule: TypingSchedule? = nil) -> some View {
        Spoken(word.text, grey: true) {
            Group {
                if let schedule {
                    TypedLine(text: line, schedule: schedule, index: 1)
                } else {
                    Text(line)
                }
            }
            .font(.body)
        }
        .accessibilityLabel("Pronounce \(word.text)")
    }

    /// A part of speech and its senses: one Chinese meaning each, then the English definition and an example. Numbers
    /// only when there is more than one sense.
    private func partSection(_ part: WordEntry.Part) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(part.label)
                .font(.system(.body, design: .serif).italic())
                .foregroundStyle(.secondary)
            ForEach(Array(part.senses.enumerated()), id: \.offset) { index, sense in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if part.senses.count > 1 {
                        Text("\(index + 1)")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sense.chinese).font(.title3.weight(.semibold))
                        if let english = sense.english, !english.isEmpty {
                            Text(english).font(.body).foregroundStyle(.secondary)
                        }
                        if let example = sense.example {
                            Spoken(example) {
                                highlighted(example)
                                    .font(.system(.body, design: .serif).italic())
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.top, 2)
                            if let translation = sense.exampleChinese {
                                Text(translation).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .transition(.blurReplace)
            }
        }
    }

    /// A sentence in use: the two lines it is typically said in, each after a dash as dialogue is set, with its Chinese
    /// under it as an example's is, and the sentence itself in bold, as the word is in an example. Tapping a line says
    /// it.
    private func exchangeSection(_ lines: [WordEntry.Line]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("—")
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 6) {
                        Spoken(line.english) {
                            Text(line.english)
                                .font(.system(.body, design: .serif).italic())
                                .bold(EntryStyle.key(line.english) == EntryStyle.key(title))
                                .multilineTextAlignment(.leading)
                        }
                        if !line.chinese.isEmpty {
                            Text(line.chinese).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.blurReplace)
            }
        }
    }

    /// Collocations with their Chinese meanings; tapping one says it. Each meaning follows its phrase on the same line
    /// when every phrase fits so; otherwise all go under their phrases, as under the examples, so a long phrase never
    /// splits its Chinese across two lines.
    private func phraseList(_ phrases: [WordEntry.Collocation]) -> some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(phrases, id: \.self) { phrase in
                    Spoken(phrase.phrase) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(phrase.phrase).font(.system(.body, design: .serif))
                            Text(phrase.chinese).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(phrases, id: \.self) { phrase in
                    Spoken(phrase.phrase) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phrase.phrase).font(.system(.body, design: .serif))
                                .multilineTextAlignment(.leading)
                            Text(phrase.chinese).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Under the headword of a word with no entry: nothing while a new one is being written (the typing above says
    /// so), otherwise what went wrong and the system dictionary as a way out.
    @ViewBuilder
    private var noEntry: some View {
        if !lexicographer.isWriting(word) {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = lexicographer.failure(for: word) {
                    Text(failure).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(AIAccess.isAvailable || !AIConsent.given
                         ? "No definition found." : "Add an OpenAI API key in Settings for an entry.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Button("Look Up in Dictionary", systemImage: "character.book.closed") { showingSystemDictionary = true }
                    .buttonStyle(.glass)
            }
            .padding(.top, 20)
        }
    }

    /// While an older entry is being brought up to the current shape, or after that failed.
    @ViewBuilder
    private var entryStatus: some View {
        if lexicographer.isWriting(word) {
            Text("Updating the entry…").font(.footnote).foregroundStyle(.secondary)
        } else if let failure = lexicographer.failure(for: word) {
            Text(failure).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// A note kept from the word's conversation: the question in the record's grey, the gist of its answer under it.
    private func noteView(_ note: WordNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.question).font(.body).lineSpacing(4).foregroundStyle(.secondary)
            MixedText(note.answer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A section set apart by space rather than rules, under a small capitals heading, as dictionaries do.
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 38)
    }

    /// Sentence with the word (or a form of it) in bold, in the sentence's own colour: blue would read as a link.
    private func highlighted(_ sentence: String) -> Text {
        var attributed = AttributedString(sentence)
        let stem = String(word.text.lowercased().prefix(max(word.text.count - 2, 3)))
        if let range = attributed.range(of: stem, options: .caseInsensitive) {
            var end = range.upperBound
            while end < attributed.endIndex, attributed.characters[end].isLetter {
                end = attributed.characters.index(after: end)
            }
            attributed[range.lowerBound..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    // MARK: Actions

    /// The wall takes the card away once this page has zoomed back into it.
}

/// The word pages, one at a time, in the wall's order: the user goes up to the word before and down to the word after
/// without going back to the wall (user, 2026-10-07: "左下角我希望有上下这样方便切换单词"). Turning to another word,
/// the page showing goes off one way and the next comes in from the other, together, as pages turn; the bars stay
/// where they are (the first try swapped the page at once and brought only the new words in: "这个上下切换的这个动画
/// 还是不够流畅"). It closes into the card of the word it shows, which the wall keeps in view behind it (`onShow`).
/// Opened from review, it is the one word's page and nothing more: no other words to turn to, no menu, no AI, only ✕ to
/// close it (`onClose`; user, 2026-10-09: "长按出来的页面不要。。。和ai吧").
struct WordPager: View {
    /// What the page zooms out of and closes into, on the wall. Review zooms its own page out of its card.
    let zoom: Namespace.ID?
    /// The words before and after one on the wall; none in review.
    let neighbors: ((Word) -> (previous: Word?, next: Word?))?
    let onShow: (Word) -> Void
    let onDelete: (Word) -> Void
    /// In review: closes the page, from ✕ at the top left, where every ✕ in the app is (user, 2026-10-09: "左右叉叉都统一在
    /// 左上角吧").
    let onClose: (() -> Void)?

    @Environment(\.modelContext) private var context
    @State private var current: Word
    /// The side the page showing came in from: the bottom for the word after, the top for the one before.
    @State private var edge: Edge = .bottom
    @State private var titleHidden = false
    /// While a page turns, its headword passes under the bar on its way in from above: the bar's word would flash.
    @State private var turning = false
    @State private var showingSystemDictionary = false
    @State private var showingChat = false
    /// What stands between a redraw or a rewrite and AI: agreeing to it, points, or a key.
    @State private var gate: AIGate?
    private let illustrator = Illustrator.shared
    private let lexicographer = Lexicographer.shared

    init(word: Word, zoom: Namespace.ID? = nil, neighbors: ((Word) -> (previous: Word?, next: Word?))? = nil,
         onShow: @escaping (Word) -> Void = { _ in }, onDelete: @escaping (Word) -> Void = { _ in },
         onClose: (() -> Void)? = nil) {
        _current = State(initialValue: word)
        self.zoom = zoom
        self.neighbors = neighbors
        self.onShow = onShow
        self.onDelete = onDelete
        self.onClose = onClose
    }

    var body: some View {
        let word = current
        let (previous, next) = neighbors?(word) ?? (nil, nil)
        ZStack {
            WordPage(word: word) { hidden in
                // Only the page showing says where its headword is, once it has stopped moving.
                guard word.id == current.id, !turning else { return }
                withAnimation(.easeInOut(duration: 0.2)) { titleHidden = hidden }
            }
            .id(word.id)
            // The system's push, as it is: the user's choice (2026-10-08). Two attempts to refine it were worse: a
            // page sliding over the other, dimmed and with a shadow ("太丑了"), and the push without its fade ("还是丑的，
            // 甚至没有…我之前一直说好的那版好").
            .transition(.push(from: edge))
        }
        .safeAreaInset(edge: .bottom) {
            if onClose == nil { bottomBar(previous: previous, next: next) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(lexicographer.generation(for: word)?.headword ?? word.text)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(titleHidden ? 1 : 0)
            }
            .sharedBackgroundVisibility(.hidden)
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close, action: onClose)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Look Up in Dictionary", systemImage: "character.book.closed") {
                            showingSystemDictionary = true
                        }
                        Button(word.imageData == nil ? "Draw Picture" : "Redraw Picture",
                               systemImage: "wand.and.stars") {
                            if let stop = AIGate.check(needing: Points.newWord) { gate = stop } else { illustrator.draw(word) }
                        }
                        .disabled(illustrator.isDrawing(word) || word.entry?.pictureIdea == nil)
                        Button("Rewrite Entry", systemImage: "pencil.line") {
                            if let stop = AIGate.check(needing: Points.newWord) {
                                gate = stop
                            } else {
                                lexicographer.write(word, rewrite: true)
                            }
                        }
                        .disabled(lexicographer.isWriting(word))
                        // The way back for a word review's menu left out (user, 2026-10-09), and a way to leave one out
                        // from here.
                        Button(word.hiddenFromReview ? "Show in Review" : "Don’t Show in Review",
                               systemImage: word.hiddenFromReview ? "eye" : "eye.slash") {
                            word.hiddenFromReview.toggle()
                            try? context.save()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(word) }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSystemDictionary) {
            SystemDictionaryView(term: word.text).ignoresSafeArea()
        }
        .sheet(item: $gate) { AIGateSheet(gate: $0) }
        // The whole screen, as on the wall ("应该是直接做成全屏的").
        .fullScreenCover(isPresented: $showingChat) {
            ChatView(topic: .word(word))
        }
        #if DEBUG
        // `-openWord <word> -openWordChat YES`: the word's conversation, opened with its page.
        .onAppear { if UserDefaults.standard.bool(forKey: "openWordChat") { showingChat = true } }
        #endif
        .modifier(ZoomsOut(of: word.id, in: zoom))
    }

    /// Turns to `word`, coming in from `edge`. The side is settled first, so that the page going off takes the
    /// opposite one: a page leaves the way it was told to when it last drew.
    private func turn(to word: Word, from edge: Edge) {
        self.edge = edge
        DispatchQueue.main.async {
            // A page comes in at its top, its headword in view. On the system's own push's clock (measured in the
            // simulator, 2026-10-09, Settings pushing General: a critically damped spring of about 0.3 s, settled by
            // 0.3 s); at 0.5 s the page crept over its last ten points for a third of a second after it had all but
            // arrived (user: "上下切换的这个动画，还是不够好").
            titleHidden = false
            turning = true
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                current = word
            } completion: {
                turning = false
            }
            onShow(word)
        }
    }

    /// Floating at the foot of the page where the wall's bar floats: on the left, the word before this one and the
    /// word after it on the wall; on the right, AI, to ask about this word (user, 2026-10-07: "右下角放一个ai按钮呗，左下
    /// 角我希望有上下这样方便切换单词").
    private func bottomBar(previous: Word?, next: Word?) -> some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                if neighbors != nil {
                    HStack(spacing: 0) {
                        stepButton("chevron.up", label: "Previous Word", to: previous, from: .top)
                        stepButton("chevron.down", label: "Next Word", to: next, from: .bottom)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                Spacer(minLength: 0)
                Button { showingChat = true } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: WallMetrics.barHeight, height: WallMetrics.barHeight)
                        .contentShape(.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask AI")
            }
        }
        .padding(.horizontal, WallMetrics.barInset)
        .padding(.bottom, WallMetrics.barInset - 34)
    }

    private func stepButton(_ symbol: String, label: LocalizedStringKey, to word: Word?, from edge: Edge) -> some View {
        Button {
            if let word { turn(to: word, from: edge) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(word == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: WallMetrics.barHeight, height: WallMetrics.barHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(word == nil)
        .accessibilityLabel(label)
    }
}

/// The page zooms out of its card on the wall and closes back into it. (Review zooms the page it shows itself.)
private struct ZoomsOut: ViewModifier {
    let id: UUID
    let zoom: Namespace.ID?

    init(of id: UUID, in zoom: Namespace.ID?) {
        self.id = id
        self.zoom = zoom
    }

    func body(content: Content) -> some View {
        if let zoom {
            content.navigationTransition(.zoom(sourceID: id, in: zoom))
        } else {
            content
        }
    }
}

/// Text that reads itself aloud when tapped and lights up while it is being read (`Reading`): the feedback the page
/// gives in place of speaker buttons.
private struct Spoken<Label: View>: View {
    let text: String
    /// Whether it rests grey rather than black.
    var grey = false
    @ViewBuilder var label: Label
    private let speech = Speech.shared
    @Environment(\.readingColor) private var readingColor
    /// This text, as what was tapped while it is read: only it lights up, not the same text elsewhere on the page.
    @State private var reader = UUID()

    init(_ text: String, grey: Bool = false, @ViewBuilder label: () -> Label) {
        self.text = text
        self.grey = grey
        self.label = label()
    }

    var body: some View {
        let reading = speech.isReading(reader)
        Button {
            speech.speak(text, from: reader)
        } label: {
            label.foregroundStyle(reading ? Reading.lit(readingColor, grey: grey)
                                          : grey ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .animation(.reading(reading), value: reading)
    }
}

/// What text read aloud turns while its voice plays: the colour of the word's picture (`PictureTint`); before there
/// is a picture, or when it has no vivid colour, the other of the page's two greys, black text going grey and grey
/// text black. Never the system's blue, which it used to fall back on (user, 2026-10-07: "图片还没出来的时候，那个强调
/// 色默认也不应该是蓝色，而是应该把它做成可能灰色，可能是黑色…反正不能是蓝色了").
enum Reading {
    static func lit(_ color: Color?, grey: Bool = false) -> AnyShapeStyle {
        if let color { return AnyShapeStyle(color) }
        return grey ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

extension EnvironmentValues {
    /// The colour of the word's picture, for what lights up while it is read aloud; nil without one.
    @Entry var readingColor: Color? = nil
}

extension Animation {
    /// How what is read aloud lights up and goes back: quickly as it is tapped, and slowly as its voice ends, so the
    /// light dies away rather than snapping off (user, 2026-10-07: "高亮是渐线过去的，但是…变回去的话是突变回去的";
    /// both ways had taken 0.15 s).
    static func reading(_ on: Bool) -> Animation {
        on ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.5)
    }
}

/// Apple's built-in dictionary page for a word.
struct SystemDictionaryView: UIViewControllerRepresentable {
    var term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
