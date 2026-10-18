import SwiftData
import SwiftUI

/// Review: the wall's cards one at a time, as many as the user likes, whenever they like, with no counts, no goal and no
/// end (user, 2026-10-07: "每天可以无限刷…不要格外在意每天刷了多少个，他就是想起来了就刷着玩玩"). Which card comes next
/// is the scheduler's (`Recall`): the word most likely forgotten now. A card asks with the English alone, to recall
/// what it means, or for something the user didn't know how to say, with its meaning in Chinese, to recall the English
/// (`Word.asksForEnglish`); a tap shows the answer where the card stands (`ReviewCard`). Swiping right says it was
/// remembered and left that it wasn't, either way with the answer seen or not: a word not remembered comes back a few
/// cards later. The cards are a squared deck: the next lies exactly under the one in play, so it shows only as that one
/// is pulled aside; answered, the top card flies off the way it was thrown, and the next is already there, at once
/// swipeable. Every card is opaque behind its glass, so nothing of one shows through another. The deck casts one
/// shadow, its own, the same under every card at rest; a card casts one of its own only while it is off the deck.
///
/// The swipe is made to feel like handling a real card, good to do for its own sake (user, 2026-10-07: "我还是希望能让
/// 整个这个 swipe 的这个过程的话 more addictive…so plain"): the card is picked up as the finger starts to move, lifting a
/// touch and casting its own shadow; it turns a little with the pull, as a card held at its foot does; as letting go
/// comes to answer, it clicks a little further on; thrown, it flies off as fast as it was thrown; let go short, it
/// springs back onto the deck with a slight wobble. The deck under it lies still: the next card rising to meet the
/// finger was tried and taken out (user, 2026-10-07: "要不这个往前迎接的这个动作，不要有"). One tap under the finger per card, as it is answered, however it is answered, and none otherwise
/// ("无论成功还是失败，我都希望它只对应着一次震动": a tap on picking up and another on clicking on made two or three).
/// Nothing is drawn to say which way a pull answers: a tint on the card and a mark beside it were turned down.
/// The English is read aloud as the answer shows, whichever side the card asked with, unless the phone is silenced
/// (user, 2026-10-07: "哪怕就是卡片的提示是英文，也得我们点完了之后再把这个英文发出声音来"; an English card used to read
/// itself as it came up).
///
/// Held, the card in play zooms out into its word's page, as the wall's cards open theirs, with a tap under the finger,
/// and the page closes back into it with ✕ (user, 2026-10-09: "变成这个卡片的长按…自动放大成整页…和首页一样的效果").
/// Every ✕ is at the top left ("左右叉叉都统一在左上角吧"); the menu at the top right leaves the word out of review from
/// now on, when the card falls off the deck.
///
/// A deck Ask AI handed over (`Chat.Deck`) is reviewed just the same, among its cards alone: endlessly, the card most
/// likely forgotten next, every answer counted as review (user, 2026-10-18: "跟…最主要的复习卡片一样的，是处于一个无限刷
/// 的状态的。但是有进度，建议直接复用"; it first ended once each card was remembered). Its ring is the share of its cards
/// remembered today, so it starts where the day's review left them, and goes back as one is forgotten.
struct ReviewView: View {
    /// The deck handed over that is reviewed, or none for review itself.
    var handed: Chat.Deck?

    init(deck: Chat.Deck? = nil) {
        handed = deck
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var queue = ReviewQueue()
    /// The words that can come up, every one with an entry and not left out, read from the store once as review opens.
    /// While review is open nothing more is read from the store, and answers are written to it only once the swiping
    /// pauses (`writeWhenPaused`): saving each answer as it was given made the store fetch every word again, for review
    /// and for the wall under it, 20–40 ms each time on the phone, which landed in the middle of the next swipe
    /// whenever the user swiped quickly (measured 2026-10-07).
    @State private var pool: [Word] = []
    @State private var words: [UUID: Word] = [:]
    @State private var loaded = false
    /// How firmly each word is remembered as review goes: read from the words as review opens, kept up to date here
    /// as answers are given, and written to the words answered since the last write (`unwritten`).
    @State private var states: [UUID: Recall.State] = [:]
    @State private var unwritten: Set<UUID> = []
    /// Today's review so far, for the ring at the bottom left (`TodayRing`): measured as review opens and after each
    /// answer (`measure`).
    @State private var progress = 0.0
    /// Answers given, to tell when the swiping has paused.
    @State private var answers = 0
    /// The card in play, the one under it that comes next, and answered cards on their way off.
    @State private var top: ReviewQueue.Card?
    @State private var under: ReviewQueue.Card?
    @State private var leaving: [ReviewQueue.Card] = []
    /// The card under the finger, picked up off the deck.
    @State private var held: Int?
    /// Where the deck is on the screen: how far a card must go to be off it, and what a card's turn is measured
    /// against.
    @State private var deck: CGRect = .zero
    /// How far the finger has got from where it touched the card: a touch that never moved is a tap.
    @State private var travel: CGFloat = 0
    /// Whether a finger is on the card, however its touch ends: one the system takes away ends no gesture.
    @GestureState private var touching = false
    /// Each touch counted as it starts and ends, so a hold waits on its own touch; and whether the touch in progress
    /// has opened the word's page, when letting go of it does nothing more.
    @State private var touches = 0
    @State private var opening = false
    /// By card: where it is, pulled or thrown aside; how far it has clicked on past the point where letting go
    /// answers; and whether it shows its answer.
    @State private var offsets: [Int: CGSize] = [:]
    @State private var detents: [Int: CGFloat] = [:]
    @State private var revealed: Set<Int> = []
    /// The one tap under the finger per card, as it is answered, and how hard: as hard as the throw.
    @State private var throwCount = 0
    @State private var throwStrength = 0.7
    /// The card whose word's page is open over the deck.
    @State private var opened: ReviewQueue.Card?
    /// What a card zooms out of into its word's page, and back into.
    @Namespace private var zoom
    /// Where the bottom of the screen is: how far a card falls to be off it.
    @State private var screenBottom: CGFloat = 0

    private let speech = Speech.shared
    /// What review reads aloud unasked: nothing on the card lights up for it.
    private static let reader = "review"
    /// How far a card is pulled, or would carry on if let go, before letting go answers it.
    private static let threshold: CGFloat = 110

    /// How far the card in play has been pulled aside.
    private var pull: CGSize { top.flatMap { offsets[$0.serial] } ?? .zero }

    /// Whether letting go now answers.
    private var armed: Bool { held != nil && held == top?.serial && abs(pull.width) > Self.threshold }

    /// Whether there are no cards left: none to review, or the last one has fallen off the deck.
    private var empty: Bool { loaded && top == nil && leaving.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                ZStack {
                    // The deck's shadow, under everything and always the same, whatever cards come and go above it,
                    // until there are none.
                    Color.clear
                        .aspectRatio(CardMetrics.aspect, contentMode: .fit)
                        .background(ReviewCard.shadow(opacity: empty ? 0 : 1))
                    // The deck, bottom up: the next card, the one in play, and answered cards flying off over it.
                    ForEach([under, top].compactMap { $0 } + leaving, id: \.serial) { card in
                        if let word = words[card.word] {
                            deckCard(card, word: word)
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { deck = $0 }
                .padding(.horizontal, 24)
                // Over the hint below, which a card drifting down as it goes would otherwise pass under (user,
                // 2026-10-07: "'tap the card'…难道不该在下面吗？怎么浮在最上方？").
                .zIndex(1)
                // The hint's room is kept when there is none, so the cards never move.
                Color.clear
                    .frame(height: 40)
                    .overlay { hint.opacity(empty ? 0 : 1) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .overlay {
                // Where the wall's Review button is, in the same glass, so review opens on what was tapped.
                if loaded && !empty {
                    TodayRing(progress: progress)
                        .padding(WallMetrics.barInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                // Once the last card has gone, fallen off the deck if it was left out.
                if empty {
                    ContentUnavailableView {
                        Label("Nothing to Review", systemImage: "rectangle.stack")
                    } description: {
                        Text("The words you add come up here.")
                    }
                    .transition(.opacity)
                }
            }
            .background {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { screenBottom = $0 }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                if top != nil {
                    ToolbarItem(placement: .topBarTrailing) { menu }
                }
            }
            // A deck's name over it; review itself has none.
            .navigationTitle(handed?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }
        // The word's page, zoomed out of the card and closed back into it: the page alone, to read.
        .fullScreenCover(item: $opened) { card in
            if let word = words[card.word] {
                NavigationStack {
                    WordPager(word: word, onClose: { opened = nil })
                }
                .navigationTransition(.zoom(sourceID: card.serial, in: zoom))
                // Closed with ✕ alone: the zoom's own swipe from the edge closed it too ("它不是一个左滑的逻辑").
                .interactiveDismissDisabled()
            }
        }
        // A card coming to answer clicks on a little, and back as it no longer would.
        .onChange(of: armed) { _, isArmed in
            guard let held, held == top?.serial else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.45).speed(Self.pace)) {
                detents[held] = isArmed ? (pull.width > 0 ? 14 : -14) : 0
            }
        }
        .sensoryFeedback(trigger: throwCount) { _, _ in .impact(flexibility: .solid, intensity: throwStrength) }
        // A tap as a held card opens its page, as a long press gives across the system (user, 2026-10-09: "卡片长按出来要有
        // 振动效果么？"): without it the half second held felt like nothing happening.
        .sensoryFeedback(.impact(weight: .medium), trigger: opened) { old, new in old == nil && new != nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { write() }
        }
        // A touch the system took away (a call, Control Center) ends with no gesture ending: the card held goes back
        // onto the deck. Looked at a moment later, once a gesture that did end has been dealt with.
        .onChange(of: touching) { _, touching in
            touches += 1
            guard !touching else { return hold() }
            DispatchQueue.main.async {
                opening = false
                travel = 0
                if let held, held == top?.serial { setDown(held, velocity: .zero) }
            }
        }
        .onAppear {
            guard !loaded else { return }
            let all = (try? context.fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            if let handed {
                // Its cards still on the wall, whether or not they are left out of review.
                let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                pool = handed.words.compactMap { byID[$0] }.filter { $0.entryData != nil }
            } else {
                pool = all.filter { $0.entryData != nil && !$0.hiddenFromReview }
            }
            words = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            states = words.compactMapValues(\.recall)
            measure()
            loaded = true
            #if DEBUG
            FrameLog.shared.start()
            // `-openReview YES -reviewWord <word>` starts review on that word.
            if let text = UserDefaults.standard.string(forKey: "reviewWord"),
               let word = pool.first(where: { $0.text == text }) {
                top = queue.start(with: word.id)
                dealUnder()
                // `-reviewPull <points> [-reviewLeft YES]` holds the card pulled that far aside, to look at the deck
                // under it (a negative argument would be read as another key).
                let pull = UserDefaults.standard.double(forKey: "reviewPull")
                let left = UserDefaults.standard.bool(forKey: "reviewLeft")
                if pull != 0, let top {
                    held = top.serial
                    offsets[top.serial] = CGSize(width: left ? -pull : pull, height: 0)
                }
                return
            }
            #endif
            top = queue.next(among: pool, states: states, at: .now)
            dealUnder()
        }
        .onDisappear {
            write()
            #if DEBUG
            FrameLog.shared.stop()
            #endif
        }
    }

    private func deckCard(_ card: ReviewQueue.Card, word: Word) -> some View {
        let isTop = card.serial == top?.serial
        let lifted = held == card.serial || leaving.contains(card)
        let offset = offsets[card.serial] ?? .zero
        // Turned with the pull, clockwise to the right, as a card held at its foot turns: a few degrees while it is
        // held, more as it flies.
        let turn = deck.width > 0 ? min(max(Double(offset.width / deck.width) * 8, -14), 14) : 0
        let scale = lifted ? 1.03 : 1
        let detent = detents[card.serial] ?? 0
        // Moved, turned and scaled as a picture of itself only, out of layout's sight: a drag changes nothing on it.
        return ReviewCard(word: word, revealed: revealed.contains(card.serial))
            // What its word's page zooms out of, and closes back into, in the card's own shape and colour, as on the
            // wall: the colour of its opaque back, which the source keeps at rest too (the wall's white made the card
            // whiter than the deck's).
            .matchedTransitionSource(id: card.serial, in: zoom) { source in
                source
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: deck.width * CardMetrics.radiusRatio, style: .continuous))
            }
            // Opaque behind its glass, so it looks as it does over the bare screen while hiding whatever card is under
            // it: nothing shows through, and what is covered is simply covered. It casts a shadow of its own only off
            // the deck. Kept out of the card itself, so picking it up changes nothing on it: the card's whole face was
            // worked out again as it was picked up, which cost the drag its first frames.
            .background(ReviewCard.shadow(opacity: lifted ? 1 : 0))
            .visualEffect { content, _ in
                content
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(turn))
                    .offset(offset)
                    .offset(x: detent)
            }
            #if DEBUG
            .modifier(MotionProbe(offset: offset))
            #endif
            .allowsHitTesting(isTop)
            .gesture(swipe)
            .transition(.identity)
            .accessibilityAction(named: "Show Answer", reveal)
            .accessibilityAction(named: "View Details") { opened = top }
            .accessibilityAction(named: "Knew It") { answer(remembered: true, velocity: .zero) }
            .accessibilityAction(named: "Forgot") { answer(remembered: false, velocity: .zero) }
    }

    /// Under the card, for the first ten words reviewed: how review works. Nothing else, and never a count. (With
    /// nothing marking which way a pull answers, this is where the two directions are learnt.)
    @ViewBuilder
    private var hint: some View {
        // Always there: shown only for the first ten words, it was soon missed (user, 2026-10-08: "卡片下方的…关于这个
        // 卡片怎么用的文字说明怎么没有").
        Text("Tap the card to see the answer. Swipe right if you knew it, left if you didn’t.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
    }

    /// The card in play's menu, at the top right, where the wall has its More: leaving the word out of review. (Its
    /// page, here at first, is the card's long press now.)
    private var menu: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("Don’t Show Again", systemImage: "eye.slash") {
                if let top { leaveOut(top) }
            }
        }
    }

    /// One gesture for a tap and a swipe, so a swipe let go short of answering is never taken for a tap too, which
    /// showed the answer and read it out (user, 2026-10-07): a touch that has moved more than a few points is a swipe,
    /// even if it comes back. Measured on the screen, not the card, which turns and moves under the finger.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard let top, !opening else { return }
                travel = max(travel, hypot(value.translation.width, value.translation.height))
                guard travel > 6 else { return }
                if held != top.serial {
                    // Picked up off the deck, uncovering the card under it, dealt now if the card thrown before is
                    // still on its way off.
                    dealUnder()
                    withAnimation(.snappy(duration: 0.22).speed(Self.pace)) { held = top.serial }
                    #if DEBUG
                    FrameLog.shared.mark("p")
                    #endif
                }
                // It follows the finger.
                offsets[top.serial] = value.translation
            }
            .onEnded { value in
                defer { travel = 0 }
                guard let top, !opening else { return }
                guard travel > 6 else { return reveal() }
                // Where it would come to rest, carried on by how fast it was moving when let go.
                let x = value.translation.width + value.velocity.width * 0.15
                guard abs(x) > Self.threshold else { return setDown(top.serial, velocity: value.velocity) }
                answer(remembered: x > 0, velocity: value.velocity)
            }
    }

    /// Back onto the deck, as fast as it was moving, settling with a slight wobble.
    ///
    /// The speed is the finger's along the card's way back, in lengths of that way. Taken from the sideways speed
    /// alone, a card pulled straight down, a point or two sideways, started back at many hundred lengths a second,
    /// and shot past the deck and back (user, 2026-10-08: "卡片往正下方滑动的时候，会产生一个诡异的回弹效果").
    private func setDown(_ serial: Int, velocity: CGSize) {
        let from = offsets[serial] ?? .zero
        withAnimation(.interpolatingSpring(duration: 0.5, bounce: 0.3,
                                           initialVelocity: Self.relative(velocity, from: from, to: .zero))
                      .speed(Self.pace)) {
            offsets[serial] = .zero
            detents[serial] = 0
            held = nil
        }
    }

    /// A finger held still on the card for half a second opens its word's page, zoomed out of the card, the finger
    /// still down; letting go of it then does nothing more.
    private func hold() {
        let touch = touches
        guard let card = top else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard touches == touch, travel <= 6, top == card, opened == nil else { return }
            opening = true
            opened = card
        }
    }

    /// Shows the card's answer, or asks again; the English is read as the answer shows.
    private func reveal() {
        guard let top, let word = words[top.word] else { return }
        let showing = !revealed.contains(top.serial)
        // The words asked with move into their place on a spring with the faintest settle.
        withAnimation(.spring(duration: 0.5, bounce: 0.12).speed(Self.pace)) {
            if showing { revealed.insert(top.serial) } else { revealed.remove(top.serial) }
        }
        if showing { read(word) }
    }

    /// The card is answered and goes, whether its answer was seen or not. (A card not remembered before its answer was
    /// shown used to spring back and show it, read aloud: the user took it for the swipe failing, or for a tap.)
    private func answer(remembered: Bool, velocity: CGSize) {
        guard let card = top, let word = words[card.word] else { return }
        // Kept here, and written to the word once the swiping pauses. A word forgotten today, back a few cards later or
        // in a later review, is practice: its forgetting was counted then, and remembering it now only pays it off.
        let state = states[word.id]
        let now = Date.now
        let owedToday = state.map { $0.forgotten == true && $0.reviewedAt >= Recall.dayStart(at: now) } ?? false
        if card.comeback || owedToday {
            if remembered, state?.forgotten == true {
                states[word.id]?.forgotten = false
                unwritten.insert(word.id)
            }
        } else {
            states[word.id] = Recall.reviewed(state, remembered: remembered, at: now)
            unwritten.insert(word.id)
        }
        answers += 1
        measure()
        writeWhenPaused()
        if !remembered { queue.forgot(word.id, among: pool.count) }
        #if DEBUG
        FrameLog.shared.mark("t")
        #endif
        // The one tap, as hard as the throw.
        let speed = abs(velocity.width)
        throwStrength = min(0.55 + Double(speed) / 5000, 1)
        throwCount += 1
        // Off the way it was thrown, carrying on at the speed it was let go at, speeding up evenly only if that was
        // slow, until no corner of it, turned any way, nor its shadow, is left on the screen: only then is it gone. It
        // carries its drift up or down. Sent off on a spring at a set pace, as it was, a card let go slowly leapt off at
        // over 4000 pt a second and was gone in a tenth of a second, seen in a dozen frames 30 pt apart, which looked
        // like a low frame rate (user, 2026-10-07: "是不是这个卡片消失得太早了，或者什么的，显得帧率低啊"). It doesn't
        // fade ("要不要做渐变消失…应该可能不要做"): a card thrown off a deck just goes.
        let side: CGFloat = remembered ? 1 : -1
        let from = offsets[card.serial] ?? .zero
        let reach = hypot(deck.width, deck.width / CardMetrics.aspect) / 2 * 1.03 + 40
        let out = side * (deck.midX + reach)
        let distance = abs(out - from.width)
        let start = min(max(side * velocity.width, 400), 4000)
        let end = max(start, 2800)
        let time = 2 * distance / (start + end)
        let to = CGSize(width: out, height: from.height + min(max(velocity.height * time, -300), 300))
        // Speed rising evenly from `start` to `end`: the curve leaves at `start` over the average speed. Left to a
        // SwiftUI animation, which runs a card setting off slowly at 80 frames a second before 120: moving the card
        // frame by frame at 120 throughout, from a display link, felt worse to the user (2026-10-07: "我觉得没有上上个
        // 版本好，就是80帧率的那个"), and so did pinning the screen at 120, which only made those frames 60.
        let lead = Double(2 * start / (start + end))
        withAnimation(.timingCurve(1 / 3, lead / 3, 2 / 3, (1 + lead) / 3, duration: Double(time)).speed(Self.pace)) {
            leaving.append(card)
            offsets[card.serial] = to
            held = nil
            advance()
        } completion: {
            leaving.removeAll { $0.serial == card.serial }
            offsets[card.serial] = nil
            detents[card.serial] = nil
            revealed.remove(card.serial)
            dealUnder()
        }
    }

    /// The word on the card in play is left out of review from now on, and its card falls off the deck.
    private func leaveOut(_ card: ReviewQueue.Card) {
        guard let word = words[card.word] else { return }
        word.hiddenFromReview = true
        // Saved once the card is off the screen: a save has the store fetch every word again.
        drop(card) { write() }
    }

    /// Off the deck and out of review: the card falls, as one let go of, from where it is, speeding up evenly from
    /// nothing until no corner of it, nor its shadow, is left on the screen. Down, not to a side, where it would read
    /// as an answer, and like a thrown card, it doesn't fade. The next card is already there under it, unless that was
    /// the same word, the only one left: another is dealt, or none.
    private func drop(_ card: ReviewQueue.Card, then gone: @escaping () -> Void) {
        pool.removeAll { $0.id == card.word }
        measure()
        if under?.word == card.word { under = nil }
        let from = offsets[card.serial] ?? .zero
        // From the middle of the card, lifted as it goes, past the bottom of the screen: half the card and its shadow.
        let reach = deck.height / 2 * 1.03 + 40
        let fall = max(screenBottom - deck.midY - from.height + reach, 0)
        // Leaving the screen as fast as a card thrown slowly does.
        let time = 2 * fall / 3200
        #if DEBUG
        FrameLog.shared.mark("d")
        #endif
        withAnimation(.timingCurve(1 / 3, 0, 2 / 3, 1 / 3, duration: Double(time)).speed(Self.pace)) {
            leaving.append(card)
            offsets[card.serial] = CGSize(width: from.width, height: from.height + fall)
            held = nil
            advance()
        } completion: {
            // The way an empty deck says so comes in, if this was the last card.
            withAnimation(.smooth(duration: 0.3)) { leaving.removeAll { $0.serial == card.serial } }
            offsets[card.serial] = nil
            detents[card.serial] = nil
            revealed.remove(card.serial)
            dealUnder()
            gone()
        }
    }

    /// The card under the one in play comes up into play, as it is. The card after it is dealt under it once the
    /// thrown card is off the screen, or as the card in play is picked up, if that comes first: dealt as the thrown
    /// card flew, making it cost the flight two or three frames.
    private func advance() {
        let next = under ?? queue.next(among: pool, states: states, at: .now)
        under = nil
        top = next
    }

    private func dealUnder() {
        guard top != nil, under == nil else { return }
        under = queue.next(among: pool, states: states, at: .now)
    }

    /// Today's review so far: of the words due today, the share remembered; all of it when none is due. A word is due
    /// once its chance of being remembered falls below 90%, or while it is forgotten and not remembered since
    /// (`Recall.isDue`), so the ring goes back as well as on: as a word counted remembered is forgotten, or as more words
    /// fall due (user, 2026-10-10,
    /// after hearing that reviewing on past the words due adds next to nothing: "左下角弄一个绿色的那种圆环进度条？这个进度条
    /// 可增可退？全完成就多个check？").
    private func measure() {
        let now = Date.now
        // A deck's: the share of its cards remembered today.
        if handed != nil {
            let start = Recall.dayStart(at: now)
            let done = pool.filter { word in
                states[word.id].map { $0.reviewedAt >= start && $0.forgotten != true } ?? false
            }.count
            progress = pool.isEmpty ? 1 : Double(done) / Double(pool.count)
            return
        }
        let start = Recall.dayStart(at: now)
        var done = 0, due = 0
        for word in pool {
            let state = states[word.id]
            if Recall.isDue(state, since: word.createdAt, at: now) {
                due += 1
            } else if let state, state.reviewedAt >= start {
                done += 1
            }
        }
        progress = done + due == 0 ? 1 : Double(done) / Double(done + due)
    }

    /// Writes the answers given to their words and saves them, once no answer has come for 2 s and no card is held or
    /// moving; and as review closes, or the app leaves the screen.
    private func writeWhenPaused() {
        let given = answers
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard answers == given, held == nil, leaving.isEmpty else { return }
            write()
        }
    }

    private func write() {
        for id in unwritten { words[id]?.recall = states[id] }
        unwritten.removeAll()
        if context.hasChanges { try? context.save() }
    }

    private static var pace: Double { reviewPace }

    private func read(_ word: Word) {
        speech.speak(word.text, from: Self.reader, unasked: true)
    }

    /// A gesture's speed along a move in the plane as a spring's starting velocity, in lengths of the move per second:
    /// the part of it that goes the move's way. Nothing for a move too short to have a way.
    private static func relative(_ velocity: CGSize, from: CGSize, to: CGSize) -> Double {
        let way = CGSize(width: to.width - from.width, height: to.height - from.height)
        let length = way.width * way.width + way.height * way.height
        guard length > 16 else { return 0 }
        return Double((velocity.width * way.width + velocity.height * way.height) / length)
    }
}

/// A review card: the wall's card for the word, as big as the screen allows: the English, its Chinese line, the
/// picture. All of it is laid out where it belongs on the answer's side from the start; asking, only the words it asks
/// with show, moved to the middle of the card: the English, to recall what it means, or the meaning in Chinese, to
/// recall the English. As the answer shows, those words move into their place, the very same words, never a second
/// copy (user, 2026-10-07: "全部信息里面有一部分是点击之前的文字，为什么他们之间没有做一个匹配？"), and the rest comes
/// in around them. Nothing turns over: a glass card turning edge-on looked wrong ("我们这个世界太玻璃，所以做翻页这个
/// 动画的话，似乎有点诡异").
private struct ReviewCard: View {
    let word: Word
    var revealed: Bool

    /// The inside of the card, and where in it the words the card asks with lie on the answer's side.
    @State private var area: CGSize = .zero
    @State private var cueSlot: CGRect = .zero

    private static let space = "card"

    /// The opaque back a card lies on, in the screen's own colour, casting the shadow of a card: soft, a little below,
    /// as the glass's own would. The deck lies on one too. Cast by the card's shape alone, which is cheaper to draw as
    /// it moves than a shadow of everything on it.
    static func shadow(opacity: Double) -> some View {
        CardShape()
            .fill(Color(.systemGroupedBackground))
            .shadow(color: .black.opacity(0.16 * opacity), radius: 20, y: 8)
    }

    var body: some View {
        Color.clear
            .aspectRatio(CardMetrics.aspect, contentMode: .fit)
            .background {
                // The card itself: glass with nothing in it. What is on the card lies over it, not in it: words in the
                // glass were drawn off their place on it while the card was turned, by as much as 25 pt at 3°, so
                // they slid about on it as it moved (user, 2026-10-07: "卡片里面的内容和这个卡片本体在滑动的时候是有
                // 视差效果的").
                Color.clear
                    .glassEffect(.regular, in: CardShape())
                    .glassEffectTransition(.identity)
                    // Clipped to its shape, the glass casts no shadow of its own: the deck's one shadow lies under
                    // every card at rest, and a card off the deck casts its own (`shadow(opacity:)`, laid under it).
                    .clipShape(CardShape())
            }
            .overlay {
                GeometryReader { proxy in
                    let s = proxy.size.width / CardMetrics.baseWidth
                    content(scale: s)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .coordinateSpace(.named(Self.space))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
                        .padding(20 * s)
                }
            }
            .contentShape(CardShape())
    }

    /// The answer's side, set as the wall's card is (`WordCard`), at its scale.
    private func content(scale s: CGFloat) -> some View {
        let parts = word.summaryParts
        let asksEnglish = word.asksForEnglish
        // The Chinese line in the wall card's grey; the meaning asked with is in the text's own colour until the
        // answer shows, turning grey as it settles into the line.
        let grey = Color(uiColor: .secondaryLabel)
        return VStack(alignment: .leading, spacing: 0) {
            piece(cue: !asksEnglish, delay: 0.12) { lean in
                Text(word.text)
                    .font(.system(size: 24 * s, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .textRenderer(LeaningLines(lean: lean))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !parts.label.isEmpty {
                    Text(parts.label).modifier(ComesIn(revealed: revealed, delay: 0.3))
                }
                piece(cue: asksEnglish, scale: 1.5, delay: 0.2) { lean in
                    Text(parts.meaning)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .textRenderer(LeaningLines(lean: lean))
                        .foregroundStyle(revealed || !asksEnglish ? grey : Color(uiColor: .label))
                }
                if !parts.rest.isEmpty {
                    Text(parts.rest).modifier(ComesIn(revealed: revealed, delay: 0.3))
                }
            }
            .font(.system(size: 16 * s))
            .foregroundStyle(grey)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6 * s)
            GeometryReader { proxy in
                if let image = PictureCache.image(for: word) {
                    Illustration(image: image, area: 10_700 * s * s, maxWidth: proxy.size.width,
                                 maxHeight: proxy.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 10 * s)
            .modifier(ComesIn(revealed: revealed, delay: 0.28))
        }
    }

    /// One piece of the answer's side. The words the card asks with (`cue`) are laid out in their place, unseen and
    /// measured, and drawn over it: moved to the middle of the card, `scale` times larger (as far as the card allows),
    /// their lines centred, until the answer shows; then they move into their place, their lines leaning over to
    /// flush left. Any other piece comes in with the answer, `delay` after it shows.
    @ViewBuilder
    private func piece<V: View>(cue: Bool, scale: CGFloat = 1, delay: Double,
                                @ViewBuilder _ text: @escaping (Double) -> V) -> some View {
        if cue {
            text(1)
                .hidden()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { cueSlot = $0 }
                .overlay {
                    let fit = cueSlot.isEmpty ? 1 : min(scale, area.width / cueSlot.width,
                                                        area.height * 0.6 / cueSlot.height)
                    text(revealed ? 1 : 0)
                        .scaleEffect(revealed ? 1 : fit)
                        .offset(revealed ? .zero : CGSize(width: area.width / 2 - cueSlot.midX,
                                                          height: area.height / 2 - cueSlot.midY))
                        // Not drawn until its place is known, so it never shows there first.
                        .opacity(cueSlot.isEmpty ? 0 : 1)
                }
        } else {
            text(1).modifier(ComesIn(revealed: revealed, delay: delay))
        }
    }
}

/// A piece of a review card that comes in with the answer, out of a slight blur, `delay` after it shows, and goes at
/// once when the card asks again; unseen, it is not read out either.
private struct ComesIn: ViewModifier {
    var revealed: Bool
    var delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .blur(radius: revealed ? 0 : 8)
            .animation((revealed ? Animation.smooth(duration: 0.4).delay(delay) : Animation.smooth(duration: 0.15))
                        .speed(reviewPace), value: revealed)
            .accessibilityHidden(!revealed)
    }
}

/// How fast review's cards move: as designed, or slowed by `-reviewSlow <factor>` in DEBUG, to catch them in
/// screenshots.
private let reviewPace: Double = {
    #if DEBUG
    let slow = UserDefaults.standard.double(forKey: "reviewSlow")
    if slow > 1 { return 1 / slow }
    #endif
    return 1
}()

/// Which word review shows next: a word not remembered, once a few other cards have passed; otherwise the word most
/// likely forgotten now (`Recall`), never one of the last few dealt, so a card never comes twice running while there
/// are others to show. There is always a next card. Review deals one card ahead, the card under the one in play.
/// Today's review as a ring at the bottom left, in a glass circle like the bar's buttons (user, 2026-10-10: "要不要放到
/// 类似按钮的那种圆形玻璃中"): green as it fills. Once nothing is left to review today, its line runs on into a check,
/// the way the iPhone Duo's status icon moves (`DuoLine`), and back the same way when a word falls due again: chosen
/// after five other ways ("大方向对了"), flung out twice as far as it first was ("更开那个我最喜欢").
/// No number: review never counts.
struct TodayRing: View {
    var progress: Double
    /// The line's way between the ring (0) and the check (1).
    @State private var line: Run
    /// How far round the ring is drawn: the ring the line comes back as, and leaves from.
    @State private var fill: Glide
    /// Whether either is still on its way, so the ring is drawn afresh every frame only then, and when both are there.
    @State private var moving = false
    @State private var until = Date.distantPast

    /// Seconds the line takes from the ring to the check, or back.
    static let duration = 1.0

    /// The line's run, at an even pace, from where it was to where it is headed.
    struct Run {
        var from: Double
        var to: Double
        var start: Date
        var length: TimeInterval

        var end: Date { start.addingTimeInterval(length) }

        func value(at date: Date) -> Double {
            guard length > 0 else { return to }
            return from + (to - from) * min(max(date.timeIntervalSince(start) / length, 0), 1)
        }
    }

    /// The ring's fill on its way to `target`: a critically damped spring, as SwiftUI's `.smooth`, sent on from where
    /// it is at the speed it has whenever it is sent somewhere else.
    struct Glide {
        var target: Double
        var offset = 0.0
        var velocity = 0.0
        var start = Date.distantPast
        var omega = 1.0

        /// As good as there: within a two-thousandth of where it set off from.
        var end: Date { start.addingTimeInterval(10 / omega) }

        func value(at date: Date) -> Double {
            let t = date.timeIntervalSince(start)
            guard t < 10 / omega else { return target }
            let since = max(t, 0)
            return target + (offset + (velocity + omega * offset) * since) * exp(-omega * since)
        }

        func speed(at date: Date) -> Double {
            let t = date.timeIntervalSince(start)
            guard t < 10 / omega else { return 0 }
            let since = max(t, 0)
            return (velocity - omega * (velocity + omega * offset) * since) * exp(-omega * since)
        }

        /// On to `target` from where it is at `date`, settling in about `response` seconds.
        func going(to target: Double, at date: Date, response: Double) -> Glide {
            Glide(target: target, offset: value(at: date) - target, velocity: speed(at: date), start: date,
                  omega: 2 * .pi / response)
        }
    }

    init(progress: Double) {
        self.progress = progress
        let time: Double = progress >= 1 ? 1 : 0
        _line = State(initialValue: Run(from: time, to: time, start: .distantPast, length: 0))
        _fill = State(initialValue: Glide(target: min(progress, 1)))
    }

    var body: some View {
        let line = line, fill = fill, moving = moving
        // Worked out frame by frame from the line's run and the ring's glide, not left to SwiftUI's animations: the two
        // were one animated value, and any change on the way, even of the ring alone, took the line on with it, twice as
        // fast and then slowing (measured 2026-10-10, as the check came back with a word forgotten and then another).
        TimelineView(.animation(paused: !moving)) { context in
            let date = moving ? context.date : .distantFuture
            let time = line.value(at: date)
            ZStack {
                // The faint track only behind the ring: gone the moment the line sets off ("甩的时候背后的淡绿不该有啊"),
                // and coming up under it over the last stretch as it lands back as the ring.
                Circle()
                    .stroke(.green.opacity(0.2), lineWidth: 3.5)
                    .opacity(line.to == 0 ? min(max(1 - time / 0.15, 0), 1) : (time > 0.0005 ? 0 : 1))
                DuoLine(fill: fill.value(at: date), time: time, duration: Self.duration, extraTurns: 0, flingScale: 2)
                    .stroke(.green, style: StrokeStyle(lineWidth: 3.5 - 0.5 * min(time * 2, 1), lineCap: .round,
                                                       lineJoin: .round))
            }
            .transaction { $0.animation = nil }
        }
        .frame(width: 22, height: 22)
        .frame(width: WallMetrics.barHeight, height: WallMetrics.barHeight)
        .glassEffect(.regular, in: .circle)
        .onChange(of: progress) { _, new in show(new) }
        .task(id: until) {
            let rest = until.timeIntervalSinceNow
            guard rest > -1 else { return }
            // A frame past the end, so the last one drawn has both where they were going.
            try? await Task.sleep(for: .seconds(max(rest, 0) + 0.05))
            if !Task.isCancelled { self.moving = false }
        }
        .accessibilityElement()
        .accessibilityLabel("Today’s Review")
        .accessibilityValue(progress >= 1 ? "Done" : "\(Int((progress * 100).rounded())) percent")
    }

    /// Takes the ring towards `progress` from wherever it is. Done, the ring closes and its line runs on into the check,
    /// or turns back that way from wherever it is. Not done, the line runs back from wherever it is into the ring as
    /// far as today has come, at its own even pace whatever happens to the ring meanwhile (user, 2026-10-10: "对勾回到
    /// 非闭环圆圈的过程中圆环如果发生变化动画会卡", "还是有问题"); the ring glides to each change on the way, from where
    /// it is, at the speed it has.
    private func show(_ progress: Double) {
        let now = Date.now
        let at = line.value(at: now)
        if progress >= 1 {
            fill = fill.going(to: 1, at: now, response: 0.3)
            if at == 0 && line.to == 0 {
                // At rest as the ring: it closes first, and the line sets off from the closed ring.
                line = Run(from: 0, to: 1, start: now.addingTimeInterval(0.3), length: Self.duration)
            } else if line.to != 1 {
                line = Run(from: at, to: 1, start: now, length: Self.duration * (1 - at))
            }
        } else {
            fill = fill.going(to: progress, at: now, response: 0.5)
            if line.to != 0 {
                line = Run(from: at, to: 0, start: now, length: Self.duration * at)
            }
        }
        moving = true
        until = max(line.end, fill.end)
    }
}

/// The springs and curves the Duo's status icon moves on, as reacticx rebuilt them (helper.ts): a damped spring whose
/// start is eased in, finished off with a smootherstep, so every part sets off softly, overshoots a touch and settles.
enum DuoMotion {
    static let decay = 6.5
    static let onset = 0.16

    static func phase(_ t: Double, _ window: (Double, Double)) -> Double {
        min(1, max(0, (t - window.0) / (window.1 - window.0)))
    }

    static func smoother(_ a: Double) -> Double { a * a * a * (a * (a * 6 - 15) + 10) }

    /// Up and back down: 0 at both ends, 1 in the middle.
    static func bump(_ a: Double) -> Double {
        let rise = a * (1 - a)
        return 64 * rise * rise * rise
    }

    static func warp(_ a: Double) -> Double {
        let eased = a < onset ? a * a / (2 * onset) : a - onset / 2
        return eased / (1 - onset / 2)
    }

    static func response(_ a: Double, _ damping: Double) -> Double {
        let natural = decay / damping
        let damped = natural * sqrt(1 - damping * damping)
        return 1 - exp(-decay * a) * (cos(damped * a) + (decay / damped) * sin(damped * a))
    }

    static func spring(_ t: Double, _ window: (Double, Double), _ damping: Double) -> Double {
        let linear = phase(t, window)
        if linear <= 0 { return 0 }
        if linear >= 1 { return 1 }
        let a = warp(linear)
        return response(a, damping) + (1 - response(1, damping)) * smoother(a)
    }

    static func softAbs(_ value: Double, _ softness: Double) -> Double {
        sqrt(value * value + softness * softness) - softness
    }
}

/// The ring's line on its way into the check, at `time` (0 to 1 of the way). Open, it is the ring filled from the top as
/// far as `fill`. Closed, it is one line drawn from its middle outwards by its curvature, as the Duo's arc is: its
/// ends draw back from the top where they met as it winds up the other way and then swings round anticlockwise, flung
/// out from the middle by its speed, leaning and stretching with it; as it comes round to where the check's long
/// stroke lies it straightens, and folds at the check's corner, overshooting a little, onto the system `checkmark`,
/// 19 pt bold, as measured in the ring's glass (2026-10-10): short stroke from (−6.5, 1.0) to (−1.67, 6.83), long one
/// to (6.88, −6.55), from the glass's middle, against a ring of radius 11.
struct DuoLine: Shape {
    var fill: Double
    var time: Double
    var duration: Double
    var extraTurns: Double
    var flingScale: Double

    // The check, against a ring of radius 11: its length, where its corner lies from its middle along it, the turn
    // there, and its middle's place and heading.
    private static let shortStroke = hypot(-1.67 - -6.5, 6.83 - 1.0)
    private static let longStroke = hypot(6.88 - -1.67, -6.55 - 6.83)
    private static let checkLength = shortStroke + longStroke
    private static let cornerFromMiddle = shortStroke - checkLength / 2
    private static let firstHeading = atan2(6.83 - 1.0, -1.67 - -6.5)
    private static let secondHeading = atan2(-6.55 - 6.83, 6.88 - -1.67)
    private static let corner = secondHeading - firstHeading
    private static let middle = CGPoint(x: -1.67 + (6.88 + 1.67) * (checkLength / 2 - shortStroke) / longStroke,
                                       y: 6.83 + (-6.55 - 6.83) * (checkLength / 2 - shortStroke) / longStroke)

    /// Degrees round the ring of the line's middle: from the middle of the ring as far as it is drawn (the bottom, closed),
    /// winding up the other way first, then swinging anticlockwise to where its heading is the long stroke's.
    private func orbit(_ t: Double) -> Double {
        let end = Self.secondHeading * 180 / .pi - 90 - 360 * extraTurns
        let start = -90 + 180 * min(max(fill, 0), 1)
        return start + 18 * DuoMotion.bump(DuoMotion.phase(t, (0, 0.24)))
            + (end - start) * DuoMotion.spring(t, (0.06, 0.8), 0.78)
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard time > 0.0005 else {
            guard fill > 0.004 else { return path }
            path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fill),
                        clockwise: false)
            return path
        }
        let unit = radius / 11
        let t = time
        // Degrees a second, round the ring.
        let step = 0.002
        let speed = (orbit(t + step) - orbit(t - step)) / (2 * step) / duration
        let flung = 2.2 * flingScale * unit * tanh(4e-6 * speed * speed / (2.2 * flingScale))
        let angle = orbit(t) * .pi / 180
        let shrink = DuoMotion.spring(t, (0.0, 0.5), 0.8)
        let bend = DuoMotion.spring(t, (0.42, 0.95), 0.72)
        let settle = DuoMotion.spring(t, (0.4, 0.9), 0.8)

        // The line's length, its middle's place and heading, and how far it has folded.
        let ringLength = 2 * Double.pi * radius * min(max(fill, 0.001), 1)
        let length = ringLength + (Self.checkLength * unit - ringLength) * shrink
            + 0.0035 * unit * DuoMotion.softAbs(speed, 60)
        let swung = CGPoint(x: center.x + (radius + flung) * cos(angle), y: center.y + (radius + flung) * sin(angle))
        let landed = CGPoint(x: center.x + Self.middle.x * unit, y: center.y + Self.middle.y * unit)
        let anchor = CGPoint(x: swung.x + (landed.x - swung.x) * settle, y: swung.y + (landed.y - swung.y) * settle)
        let heading = angle + .pi / 2 + 0.01 * speed * .pi / 180 * (1 - settle)
        let ringCurvature = 1 / (radius + flung)
        let cornerAt = Self.cornerFromMiddle * length / Self.checkLength
        let sharpness = 2.0 * unit + (0.35 * unit - 2.0 * unit) * min(bend, 1)

        func curvature(_ s: Double) -> Double {
            let spread = (s - cornerAt) / sharpness
            let fold = Self.corner * exp(-0.5 * spread * spread) / (sharpness * sqrt(2 * .pi))
            return ringCurvature * (1 - bend) + fold * bend
        }

        // Out from the middle both ways, a heading carried along by the curvature.
        let count = 140
        let ds = length / 2 / Double(count)
        var forward = [anchor]
        var point = anchor
        var direction = heading
        for i in 0..<count {
            direction += curvature((Double(i) + 0.5) * ds) * ds
            point = CGPoint(x: point.x + cos(direction) * ds, y: point.y + sin(direction) * ds)
            forward.append(point)
        }
        var backward: [CGPoint] = []
        point = anchor
        direction = heading
        for i in 0..<count {
            direction -= curvature(-(Double(i) + 0.5) * ds) * ds
            point = CGPoint(x: point.x - cos(direction) * ds, y: point.y - sin(direction) * ds)
            backward.append(point)
        }
        path.move(to: backward.last ?? anchor)
        for p in backward.reversed().dropFirst() { path.addLine(to: p) }
        for p in forward { path.addLine(to: p) }
        return path
    }
}

struct ReviewQueue {
    struct Card: Equatable, Identifiable {
        var word: UUID
        /// Shown again because it wasn't remembered a few cards ago.
        var comeback: Bool
        /// Tells one showing from the next, even of the same word.
        var serial: Int
        var id: Int { serial }
    }

    private var shown: [UUID] = []
    /// Words not remembered, and how many cards are still to be dealt before each comes back.
    private var comebacks: [UUID: Int] = [:]
    private var serial = 0

    /// How many other cards come between two showings of a word: three, or as many as there are.
    private static func gap(_ count: Int) -> Int { min(3, max(count - 1, 0)) }

    /// The word that comes next, and whether it is back because it wasn't remembered.
    private func choose(among words: [Word], states: [UUID: Recall.State], at now: Date) -> (word: UUID, comeback: Bool)? {
        guard !words.isEmpty else { return nil }
        let ids = Set(words.map(\.id))
        if let due = comebacks.first(where: { $0.value <= 0 && ids.contains($0.key) })?.key { return (due, true) }
        let recent = Set(shown.suffix(Self.gap(words.count)))
        // A word forgotten and not remembered since comes first, as the most likely forgotten: so too in a later review
        // the same day, when its comeback, here, is gone.
        let chances = Dictionary(words.map { word in
            let state = states[word.id]
            return (word.id, state?.forgotten == true ? 0 : Recall.chance(of: state, since: word.createdAt, at: now))
        }, uniquingKeysWith: { a, _ in a })
        let pick = words.filter { !recent.contains($0.id) }.min { a, b in
            let ca = chances[a.id] ?? 1, cb = chances[b.id] ?? 1
            return ca != cb ? ca < cb : a.createdAt < b.createdAt
        }
        return ((pick ?? words[0]).id, false)
    }

    mutating func next(among words: [Word], states: [UUID: Recall.State], at now: Date) -> Card? {
        guard let (word, comeback) = choose(among: words, states: states, at: now) else { return nil }
        // Dealt, whether as a comeback or in its turn, it no longer has one owed.
        comebacks[word] = nil
        for key in comebacks.keys { comebacks[key, default: 0] -= 1 }
        shown.append(word)
        if shown.count > 8 { shown.removeFirst(shown.count - 8) }
        serial += 1
        return Card(word: word, comeback: comeback, serial: serial)
    }

    /// The word wasn't remembered: it comes back once a few other cards have been dealt.
    mutating func forgot(_ word: UUID, among count: Int) {
        comebacks[word] = Self.gap(count)
    }

    #if DEBUG
    /// Deals `word` first, whatever its turn.
    mutating func start(with word: UUID) -> Card {
        shown.append(word)
        serial += 1
        return Card(word: word, comeback: false, serial: serial)
    }
    #endif
}

#if DEBUG
/// How smoothly review moves on the phone itself. Every frame a card is moved on, by the finger or by an animation, is
/// noted as SwiftUI works out where the card is (`MotionProbe`), with when each card was picked up, thrown or let fall;
/// as review closes, all of it is appended to Documents/frames.txt, to be fetched with `xcrun devicectl device copy
/// from` and read on the Mac. Nothing here asks for a frame rate (the display link this used to keep asked for 120 a second
/// itself), so the gaps between frames are the rate the cards really move at: 8.3 ms at 120 a second, 16.7 ms at 60;
/// a frame the main thread had no time for shows as a gap twice as long or more.
nonisolated final class FrameLog: @unchecked Sendable {
    static let shared = FrameLog()
    private let lock = NSLock()
    private var running = false
    private var lines: [String] = []

    func start() {
        lock.withLock {
            running = true
            lines = ["# \(Date.now.formatted(date: .numeric, time: .standard))"]
        }
    }

    /// A card moved on this frame: several cards on one frame, or one worked out twice, count once.
    func frame() {
        let now = CACurrentMediaTime()
        lock.withLock {
            guard running else { return }
            if let last = lastFrame, now - last < 0.002 { return }
            lastFrame = now
            lines.append(String(format: "f %.5f", now))
        }
    }

    private var lastFrame: CFTimeInterval?

    /// "p" as a card is picked up, "t" as one is thrown, "d" as one falls off the deck.
    func mark(_ kind: String) {
        let now = CACurrentMediaTime()
        lock.withLock {
            if running { lines.append(kind + String(format: " %.5f", now)) }
        }
    }

    func stop() {
        let text: String? = lock.withLock {
            defer { running = false; lines = []; lastFrame = nil }
            return running && lines.count > 1 ? lines.joined(separator: "\n") + "\n" : nil
        }
        guard let text else { return }
        let url = URL.documentsDirectory.appending(path: "frames.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Tells `FrameLog` of each frame a card's place is worked out on, from its offset, moving nothing itself.
nonisolated struct MotionProbe: GeometryEffect {
    var offset: CGSize

    var animatableData: CGSize.AnimatableData {
        get { offset.animatableData }
        set { offset.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        FrameLog.shared.frame()
        return ProjectionTransform()
    }
}
#endif
