import SwiftUI
import SwiftData
import UIKit.UIGestureRecognizerSubclass

/// Measurements taken from the Siri app on iOS 27. Margins and gaps stay fixed at every width;
/// the cards between them scale (see `CardMetrics`).
enum WallMetrics {
    static let margin: CGFloat = 15
    static let gap: CGFloat = 14.5
    /// iOS 27's own bottom search field (Messages): 48 pt tall, 27.5 pt in from both sides and from the bottom of
    /// the screen, so it is concentric with the display's corners.
    static let barHeight: CGFloat = 48
    static let barInset: CGFloat = 27.5
    /// With the keyboard up the system field widens to 8 pt from the screen's sides, lining up with the keys,
    /// and sits 8 pt above the keyboard (measured on the user's iPhone Air).
    static let barInsetOverKeyboard: CGFloat = 8
    /// While typing, Messages' search field shortens to make room for a 48 pt glass circle 12 pt to its right;
    /// together they keep the bar's full length.
    static let barSpacing: CGFloat = 12
    /// The home indicator's room at the bottom of the screen, which the keyboard covers.
    static let homeIndicator: CGFloat = 34

    /// How far in from the screen's sides a bottom bar sits, and how far above the bottom of the safe area, given
    /// that bottom (`keyboard`: 34 pt with the keyboard down, the keyboard's top while it is up, moving with it).
    /// Both change over the keyboard's last `barHeight` of travel, so a bar follows the keyboard exactly, into its
    /// resting place as the keyboard lands and out of it as the keyboard sets off (measured in the simulator: the
    /// safe area moves with the keyboard frame by frame, dragged keyboard and all).
    static func barPlacement(keyboard: CGFloat) -> (side: CGFloat, bottom: CGFloat) {
        // 0 at rest, 1 once the keyboard is more than a bar's height above the home indicator's 34 pt.
        let raised = min(max((keyboard - 34) / barHeight, 0), 1)
        return (barInset + (barInsetOverKeyboard - barInset) * raised,
                barInset - 34 + (barInsetOverKeyboard - barInset + 34) * raised)
    }
}

/// The wall of word cards, with one long input bar at the bottom that turns anything typed into a card.
struct HomeView: View {
    /// How the wall's cards are ordered, set in Settings (user, 2026-10-08: "这个排序的话…放在设置里面似乎更合理一些";
    /// it was in the More menu, and went back to newest first at every launch).
    enum Order: String, CaseIterable, Identifiable {
        case newest, oldest, alphabetical
        static let storageKey = "wallOrder"
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .newest: "Newest First"
            case .oldest: "Oldest First"
            case .alphabetical: "A to Z"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Word.createdAt, order: .reverse) private var words: [Word]

    @State private var path: [Word] = []
    /// The card a finger is on, outside picking: the only one taking a touch meanwhile.
    @State private var cardPress = CardPress()
    @State private var input = ""
    /// Whether what is being typed is a card the wall has, asked as it is typed.
    @State private var lookahead = DuplicateCheck.Lookahead()
    /// Set in Settings, and kept.
    @AppStorage(Order.storageKey) private var order: Order = .newest
    /// Whether this is the app's first launch here, read before anything marks it otherwise; and the syncing with
    /// iCloud, which the sample words wait for.
    @State private var firstLaunch = SampleWords.isFirstLaunch
    /// How far the keyboard reaches above the home indicator, while the wall makes room for it (`BarRoom`); whether a
    /// finger or a glide is moving the wall, and whether a finger is on it; and whether the keyboard is going.
    @State private var keyboard = KeyboardRoom()
    @State private var wallMoving = false
    @State private var wallTouched = false
    @State private var keyboardGoing = false
    /// The wall's UIKit scroll view.
    @State private var wallScroll = WallScroll()
    /// Where the navigation bar ends, for the empty wall to sit centred under it.
    @State private var wallTop: CGFloat = 0
    private let cloudSync = CloudSync.shared
    @State private var showingSettings = false
    @State private var showingReview = false
    @State private var showingAI = false
    /// What stands between a new word and AI: agreeing to it, points, or a key. What was typed stays in the field.
    @State private var gate: AIGate?
    /// The card to scroll into view next.
    @State private var revealTarget: UUID?
    /// Cards on their way out, fading where they stand before the wall closes the gap.
    @State private var leaving: Set<UUID> = []
    /// Cards taken off the wall by their menu's Delete whose words are not yet deleted: the menu's copy of the card,
    /// dissolving, still shows the word.
    @State private var removed: Set<UUID> = []
    /// A card the wall has just shown for what was typed, given one gentle press so the eye finds it.
    @State private var nudged: UUID?
    /// What was last typed and taken for a card already on the wall: typed again at once, it is added after all.
    @State private var redirected: String?
    /// Whether the bar is asking to delete the picked cards: its trash opened into the question.
    @State private var confirmingDelete = false
    /// While the wall is picking cards to delete together, the cards picked so far; nil otherwise.
    @State private var selection: Set<UUID>?
    /// A slide across the cards in progress: the card it started on, whether it picks or puts back, and what was
    /// picked before it.
    @State private var sliding: Slide?

    private struct Slide {
        var anchor: Int
        var picks: Bool
        var before: Set<UUID>
    }
    @Namespace private var zoom

    private let lexicographer = Lexicographer.shared

    private var visibleWords: [Word] {
        // No pinning (dropped 2026-10-06): a new card always enters at the top, and the wall moves the same way each time.
        // Newest first is the query's own order. Sorted again, and filtered for nothing, on every redraw of the wall,
        // the words took ~10 ms of the phone's main thread each time (2026-10-09), more than a frame's budget.
        let shown = removed.isEmpty ? words : words.filter { !removed.contains($0.id) }
        #if DEBUG
        // `-emptyWall YES`: the wall as it is with no cards, the words left alone. `-wallLimit <n>`: its first n cards.
        if UserDefaults.standard.bool(forKey: "emptyWall") { return [] }
        let limit = UserDefaults.standard.integer(forKey: "wallLimit")
        if limit > 0 { return Array(shown.prefix(limit)) }
        #endif
        switch order {
        case .newest: return shown
        case .oldest: return shown.reversed()
        case .alphabetical:
            return shown.sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
        }
    }

    var body: some View {
        let _ = WallLog.note("HomeView.body")
        let shown = visibleWords
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    CardGrid(items: shown, spacing: WallMetrics.gap, leaving: leaving, nudged: nudged,
                             selection: selection, onSlide: slide(_:)) { word, cardWidth, selected in
                        // A tap opens the card, or while the wall is picking cards, picks it or puts it back. One card
                        // opens at a time: a second finger's card, let go of after, opened a page over the first.
                        Button {
                            if selected != nil { toggle(word) } else if path.isEmpty { path.append(word) }
                        } label: {
                            WordCard(word: word)
                                .matchedTransitionSource(id: word.id, in: zoom) { source in
                                    // Tell the zoom where it lands: the card's own shape and colour,
                                    // so it doesn't shrink into a square and snap at the end.
                                    source
                                        .background(Color(.secondarySystemGroupedBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: cardWidth * CardMetrics.radiusRatio, style: .continuous))
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if let selected {
                                        SelectionCheck(selected: selected, scale: cardWidth / CardMetrics.baseWidth)
                                            .transition(.blurReplace)
                                    }
                                }
                        }
                        .buttonStyle(CardPressStyle { pressed in
                            if selected == nil { cardPress.press(word.id, pressed) }
                        })
                        .modifier(CardPressLock(press: cardPress, id: word.id, picking: selected != nil))
                        .accessibilityAddTraits(selected == true ? .isSelected : [])
                        // The long-press preview keeps the card's own corners instead of the system's default
                        // smaller ones.
                        .contentShape(.contextMenuPreview, CardShape())
                        // Lifted as a card of its own rather than the card itself, so when Delete takes the card
                        // off the wall, the lifted one still shows the word as it dissolves: lifting the card
                        // itself, the lifted copy went blank the moment the card left.
                        .contextMenu {
                            // Nothing while picking cards: a long press does nothing then.
                            if selected == nil { menu(for: word) }
                        } preview: {
                            WordCard(word: word)
                                .frame(width: cardWidth, height: cardWidth / CardMetrics.aspect)
                        }
                        .id(word.id)
                    }
                    .padding(.horizontal, WallMetrics.margin)
                    .padding(.top, 3)
                    .padding(.bottom, 16)
                    .background { ScrollViewProbe { wallScroll.found($0) } }
                }
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
                    // While the keyboard is up SwiftUI may take from the top inset to make room for it: only a larger
                    // value is the bar's own then (as in the conversation, `ChatView.top`).
                    if keyboard.room == 0 || inset > wallTop { wallTop = inset }
                }
                .onChange(of: revealTarget) {
                    guard let id = revealTarget else { return }
                    revealTarget = nil
                    reveal(id, with: proxy)
                }
            }
            // A request whose headword turned out to be a card already on the wall turns into that card, as one
            // recognised before anything is written does.
            .onChange(of: lexicographer.merge) {
                guard let merge = lexicographer.merge else { return }
                lexicographer.merge = nil
                if let word = words.first(where: { $0.id == merge.new }),
                   let existing = words.first(where: { $0.id == merge.existing }) {
                    become(word, existing)
                }
            }
            // A light tick as each card is picked or put back, and as a card already on the wall is shown.
            .sensoryFeedback(.selection, trigger: selection) { old, new in old != nil && new != nil }
            .sensoryFeedback(.impact(weight: .light), trigger: nudged) { _, new in new != nil }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The wall makes its own room under its last cards: the home indicator's and the bar's (`BarRoom`), and the
            // keyboard's while it is up (`KeyboardRoom`), set when the keyboard says it is coming or has gone, never as
            // it moves. Left to SwiftUI, the wall was laid out again on every frame of a keyboard dragged by a finger,
            // and shook by up to 11 pt, then jumped as the keyboard let go (measured on the phone, 2026-10-09: "这是其他
            // 情况"); and even the home indicator's room, left to SwiftUI, changed as a dragged keyboard neared the
            // bottom, which threw a wall pulled past its top straight back up under the finger (measured in the
            // simulator: −378 to −116 in one frame).
            .safeAreaInset(edge: .bottom) { BarRoom(keyboard: keyboard) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                // Not for another page's keyboard over the wall (Ask AI's, a word's question), which the wall would
                // otherwise be laid out again for, out of sight, just as that keyboard takes the main thread.
                guard !covered else { return }
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                let screen = UIScreen.main.bounds
                // At once: the room comes in under the keyboard, before it has moved.
                keyboardGoing = false
                keyboard.room = max(screen.maxY - end.minY - WallMetrics.homeIndicator, 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                keyboardGoing = true
                giveUpKeyboardRoom(alongKeyboard: note)
            }
            .scrollTargetBehavior(GlideTargetReader { wallScroll.carrier })
            .onScrollPhaseChange { old, phase in
                WallLog.note("phase \(old) -> \(phase)")
                wallMoving = phase != .idle
                wallTouched = phase == .interacting
                if wallTouched { wallScroll.carrier?.drop() }
                // Let go of as the keyboard goes down: on through the hold its putting away makes (`carryRelease`),
                // before the keyboard's room goes, to rest short of where the wall will end without it.
                if old == .interacting && !wallTouched, let scrollView = wallScroll.view {
                    wallScroll.carrier?.carryRelease(end: endWithoutKeyboardRoom(scrollView))
                }
                if keyboardGoing { giveUpKeyboardRoom() }
            }
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentInsets.top, $0.contentInsets.bottom, $0.containerSize.height, $0.contentSize.height] } action: { _, v in
                WallLog.note(String(format: "geo offset %.1f insets %.1f %.1f container %.1f content %.1f", v[0], v[1], v[2], v[3], v[4]))
            }
            // Dragged down into the keyboard, the wall takes the keyboard down with the finger, at its top too (user,
            // 2026-10-09: "卡片在顶部的时候，下滑的时候不跟手", when the keyboard waited there for the finger to let go).
            .scrollDismissesKeyboard(.interactively)
            // The gray runs on behind the keyboard. A plain colour background stops at the keyboard's top, and the
            // window's white then shows in the keyboard's rounded corners and through its glass.
            .background { Color(.systemGroupedBackground).ignoresSafeArea() }
            // No room at the bottom but the wall's own (`BarRoom`), kept while picking cards, when the bar is gone, so the
            // wall doesn't move as picking starts and ends.
            .ignoresSafeArea(.all, edges: .bottom)
            // Our own bar rather than the system's bottom search field: this field adds, it never searches, and the
            // search field insisted on a magnifying glass, a clear button beside our ✕ and a Search return key.
            // While picking cards, nothing in its place: its buttons are at the top (`toolbar`). The bar rides the keyboard
            // itself (`KeyboardRidingBar`), not the safe area, which moves on a curve of its own and left the bar ahead
            // of the keys on the way up and behind them on the way down.
            // With no cards, the empty wall, centred between the navigation bar and the input bar, and carried with them
            // as the keyboard moves, in the keyboard's own animation (`fillsAbove`). Centred in the wall's own room, it
            // jumped by half the keyboard in one frame as the keyboard set off, the room coming in at once (user,
            // 2026-10-09: "在没有卡片时呼出addaword，空白placeholder会有诡异的弹跳"). It comes up as the last card goes
            // and gives way as the first one comes in.
            .overlay {
                if shown.isEmpty {
                    KeyboardRidingBar(restingGap: WallMetrics.barInset - WallMetrics.homeIndicator + WallMetrics.barHeight
                                          + Self.emptyMargin,
                                      raisedGap: WallMetrics.barInsetOverKeyboard + WallMetrics.barHeight + Self.emptyMargin,
                                      fillsAbove: true, top: wallTop + Self.emptyMargin) {
                        EmptyWall()
                    }
                    .ignoresSafeArea()
                    // Faded, not blurred in: around the container, `.blurReplace` or `.allowsHitTesting(false)` (it lets
                    // every touch through anyway) left its keyboard guide 52 pt off the keyboard, and a further 34 until
                    // the keyboard had come once (measured in the simulator), so the empty wall rested higher.
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.5), value: shown.isEmpty)
            .overlay {
                if selection == nil {
                    // A gliding wall glides on through the keyboard's coming (`GlideCarrier`): taken over as the finger
                    // comes down on the bar, so the glide is on the render server before the keyboard holds the main
                    // thread (asked for only as the field took the keyboard, it got there after the hold), or then, if
                    // the finger came down before the wall was let go of.
                    KeyboardRidingBar(restingGap: WallMetrics.barInset - WallMetrics.homeIndicator,
                                      raisedGap: WallMetrics.barInsetOverKeyboard,
                                      onTouch: { wallScroll.carrier?.carry() }) {
                        InputBar(text: $input, onSubmit: submit, onReview: { showingReview = true },
                                 onAI: { showingAI = true }, onBeginEditing: { wallScroll.carrier?.carry() })
                    }
                    .ignoresSafeArea()
                }
            }
            // What is being typed is asked about as soon as the typing pauses, so Return finds the answer in.
            .onChange(of: input) { lookahead.typed(input) { writtenCards } }
            // The More button sits in the navigation bar, where the word page has its own, so the two line up. The
            // bar is never hidden: hiding it on the wall and showing it on the word page made the page's content
            // jump at the end of the zoom, and lose its buttons after a back swipe let go halfway.
            .toolbar {
                if let selection {
                    // Picking cards: the way out at the top left, where every ✕ in the app is (user, 2026-10-09:
                    // "左右叉叉都统一在左上角吧"; it stood where More is), and Delete at the top right, where the
                    // conversation keeps its own ("删除按钮放到右上角？"; it was in a bottom bar, as in Photos). Nothing
                    // else is needed (2026-10-07: "大道至简"; a Select All, a count and a confirmation had made it fussy).
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close, action: endSelecting)
                    }
                    ToolbarItem(placement: .topBarTrailing) { deleteButton(selection.count) }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { moreButton(empty: shown.isEmpty) }
                }
            }
            .navigationDestination(for: Word.self) { word in
                // Deleted from its page: back to the wall first, onto the card (about 0.15 s), which then leaves
                // after a beat, so the eye has found it. Turned to another word, the wall behind keeps that word's
                // card in view, for the page to close into.
                WordPager(word: word, zoom: zoom, neighbors: neighbors, onShow: { revealTarget = $0.id }) { deleted in
                    path.removeAll()
                    remove([deleted], after: .milliseconds(300))
                }
            }
        }
        // Anything that covers the wall puts the keyboard away: a card's page, review, settings. The field keeps the
        // keyboard through Return, so it no longer goes when the field goes out of sight (user, 2026-10-07: "我怎么从
        // 这个二级页面返回到这个一级页面呢？…那个键盘还竖在那儿呢").
        .onChange(of: covered) { _, covered in
            if covered { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .sheet(isPresented: $showingSettings, onDismiss: resumePending) {
            SettingsView()
        }
        .sheet(item: $gate, onDismiss: resumePending) { gate in
            // Agreed: the balance first, so a word that needs more points than are left asks for them.
            AIGateSheet(gate: gate) { Task { await Points.shared.refresh(); submit() } }
        }
        .fullScreenCover(isPresented: $showingReview) {
            ReviewView()
        }
        // The whole screen, as a page of its own ("应该是直接做成全屏的").
        .fullScreenCover(isPresented: $showingAI) {
            ChatView(topic: .wall)
        }
        // The sample words, for a new wall, once what the user's iCloud holds has been looked at.
        .onChange(of: cloudSync.looked, initial: true) {
            guard cloudSync.looked, firstLaunch else { return }
            firstLaunch = false
            SampleWords.insertIntoEmptyWall(context)
        }
        .task {
            KeyboardWarmup.run()
            SampleWords.refreshEntriesOnce(in: context)
            SampleWords.refreshImagesOnce(in: context)
            ImageMaintenance.trimStoredImagesOnce(in: context)
            ImageMaintenance.removeUnnamedPhotosOnce(in: context)
            // Every written card's headword gets its voice ahead of any tap (cards still waiting for AI show the
            // user's own words, which are not read).
            Speech.shared.prepare(all: words.filter { $0.entry != nil && !$0.awaitsHeadword }.map(\.text))
            resumePending()
            await Points.shared.refresh()
            await debugLaunch()
        }
        // The conversations opened from the wall and from its cards' pages put the words their answers offer on it, as
        // if typed into its field.
        .environment(\.keepOnWall, { text in Task { await add(text) } })
    }

    /// The keyboard is going: its room goes as soon as no finger is on the wall and the wall isn't pulled past its top,
    /// where a change of room threw it back up in one frame (measured in the simulator). Kept until the wall stood
    /// still, the room stayed in through a glide set off as the keyboard went, and a wall flung on to its end showed it
    /// there as an empty space under the last cards (user, 2026-10-09: "先把它抬起来，然后收回去，迅速滚到最底下的时候，
    /// 下面的话会有一大块白色的"). The last cards come down into the room if they stood over it: with the keyboard, in its
    /// own animation, from a still wall (the ✕, say; moved by SwiftUI, they stood still while the keyboard's going held
    /// the main thread); otherwise on a curve of their own.
    private func giveUpKeyboardRoom(alongKeyboard note: Notification? = nil) {
        guard keyboard.room != 0, !wallTouched, let scrollView = wallScroll.view,
              scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top - 1 else { return }
        // Whether the wall stands so far down that its last cards come down into the room: read off the scroll view as
        // it is (kept as the wall scrolled, the answer was once left over from the room coming in, and the room went
        // in an animation, laying the wall out on every frame for 0.7 s).
        let end = endWithoutKeyboardRoom(scrollView)
        WallLog.note("give up room: near \(scrollView.contentOffset.y > end) moving \(wallMoving) note \(note != nil) "
                     + String(format: "offset %.1f end %.1f", scrollView.contentOffset.y, end))
        if scrollView.contentOffset.y <= end {
            // Without the animation the end of a glide hands the phase change in with, which redrew the wall's inset
            // on every frame for 0.7 s, out of sight.
            withTransaction(\.disablesAnimations, true) { keyboard.room = 0 }
        } else if let note, !wallMoving {
            scrollView.scroll(to: end, alongKeyboard: note)
            keyboard.room = 0
        } else {
            withAnimation(.smooth(duration: 0.35)) { keyboard.room = 0 }
        }
    }

    /// Where the wall's end will be once the keyboard's room has gone: its top, for a wall shorter than the screen.
    /// Taken as it came out, past the top, a wall of a card or two jumped up as the ✕ put the keyboard away and then
    /// came down 220 pt below where it had stood, and stayed there (user's screen recording, 2026-10-10).
    private func endWithoutKeyboardRoom(_ scrollView: UIScrollView) -> CGFloat {
        max(scrollView.end - keyboard.room, -scrollView.adjustedContentInset.top)
    }

    /// Space between the empty wall's room and the bars above and below it.
    private static let emptyMargin: CGFloat = 16

    /// Whether another page covers the wall: a card's, review, settings, Ask AI.
    private var covered: Bool { !path.isEmpty || showingSettings || showingReview || showingAI }

    /// Delete, for the picked cards; it waits for one to be picked. Deleting several asks first (user, 2026-10-07:
    /// "multi-select…点击删除之后，它应该问我们确定要删除吗"), the trash itself opening into the question ("删除的按钮
    /// 变成这个，你确定要删除吗的这种问题"): what will happen and one button to answer it, no title, no rules, as Photos
    /// asks ("它只是 description 加一个按钮"). A single card, from its menu or its page, goes without asking.
    ///
    /// A system bar's button and its question: only a bar's own button opens into the question that takes its place.
    /// A panel of our own grew out of a trash in our own bar in 0.4 s, against Photos' 0.15 s with a touch of spring,
    /// and shrank back as slowly (user, 2026-10-08: "都和苹果自带的那种动画不符，而且很慢"); the system's question from our
    /// own bar was a bubble with an arrow ("肯定不是这个样子").
    private func deleteButton(_ count: Int) -> some View {
        Button("Delete", systemImage: "trash") { confirmingDelete = true }
            .disabled(count == 0)
            .confirmationDialog(count == 1 ? "Delete Word" : "Delete \(count) Words", isPresented: $confirmingDelete,
                                titleVisibility: .hidden) {
                Button(count == 1 ? "Delete Word" : "Delete \(count) Words", role: .destructive, action: deleteSelected)
            } message: {
                // What will happen, and nothing more: asking is warning enough (user, 2026-10-07, of a "This can’t be
                // undone." after it: "是不是不需要").
                Text(count == 1 ? "This word will be deleted." : "These \(count) words will be deleted.")
            }
    }

    private func moreButton(empty: Bool) -> some View {
        Menu {
            Button("Select", systemImage: "checkmark.circle", action: startSelecting)
                .disabled(empty)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// A single card goes at once, with nothing to confirm: only deleting several asks first (user, 2026-10-07: "单个
    /// 删除的时候，长按删除的时候，那不要再次确认。就是只有 multi-select").
    @ViewBuilder
    private func menu(for word: Word) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            // Off the wall at once: with the card gone, the menu dissolves its lifted copy where it stands while the
            // others close the gap, as the system's own apps do. Taken off any later, or with a removal transition,
            // the card had the menu put its copy back in its place and leave it there, still, for a second, over
            // the others moving under it (2026-10-07).
            let id = word.id
            withAnimation(.smooth(duration: 0.5)) { _ = removed.insert(id) }
            Task {
                // The word itself goes once the menu has let go of its copy, which shows the word until then: deleted
                // at once, the copy went blank as it dissolved.
                try? await Task.sleep(for: .seconds(1))
                context.delete(word)
                try? context.save()
                removed.remove(id)
                lexicographer.forgetGeneration(for: id)
                Chats.shared.forget(id.uuidString)
            }
        }
    }

    /// The cards written so far, as `DuplicateCheck` weighs them.
    private var writtenCards: [DuplicateCheck.Card] {
        words.compactMap { word in
            word.entry.map { DuplicateCheck.Card(id: word.id, headword: word.text, meaning: $0.summary, typed: word.request) }
        }
    }

    /// The words before and after one on the wall, as it is ordered now.
    private func neighbors(of word: Word) -> (previous: Word?, next: Word?) {
        let shown = visibleWords
        guard let index = shown.firstIndex(where: { $0.id == word.id }) else { return (nil, nil) }
        return (index > 0 ? shown[index - 1] : nil, index + 1 < shown.count ? shown[index + 1] : nil)
    }

    /// Anything typed becomes a card at the top of the wall, a new word's or the card the wall has for it, unless it is
    /// a card's word for word: that card is shown where it is.
    private func submit() {
        let text = input
        // A card the wall already has needs nothing of AI; a new one waits in the field while the user agrees to AI,
        // tops up their points or enters a key.
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, !words.contains(where: { $0.matches(typed) }), let stop = AIGate.check(needing: Points.newWord) {
            // The keyboard goes, or the sheet's button rode up on it into the text.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            gate = stop
            return
        }
        let asked = lookahead.take(text)
        input = ""
        Task { await add(text, asked: asked) }
    }

    /// Adds what was typed as a new card at the top of the wall and starts its entry; a word the wall has a card for
    /// already turns into that card there (`become`). Returns the new word, if it is one. `asked` is the question
    /// about it that went out as it was typed (`lookahead`), if one did.
    ///
    /// Words that are a card's word for word (`Word.matches`: its English, what was first typed for it, or a meaning
    /// in Chinese) add nothing: that card is shown where it is (user, 2026-10-07: "完全能匹配…那干嘛要新建这个卡片").
    /// Anything else goes up at once as a new card, the user's words waiting on it as on any new card. Whether it is a
    /// card the wall has in other words ("雨伞" for "umbrella") is known only a quarter of a second to a second later,
    /// or, when the quick question isn't sure, once AI's headword comes, two or three seconds in; and then the card
    /// becomes that one, rather than the wall taking the new one away again ("这种先加入再消失的状况，很不优雅"; "变成
    /// 已有的那一张是一个好的思路"). Nothing is written or drawn for it until the quick answer is in. The same words typed
    /// again straight after are written after all: the user meant something new.
    @discardableResult
    private func add(_ typed: String, asked: Task<UUID?, Never>? = nil) async -> Word? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let same = words.first(where: { $0.matches(text) }) {
            show(same.id)
            return nil
        }
        let cards = writtenCards
        let word = Word(text: text)
        word.request = text
        context.insert(word)
        try? context.save()
        revealTarget = word.id
        lexicographer.expect(word)
        if text != redirected {
            let answer: UUID?
            if let asked {
                answer = await asked.value
            } else {
                answer = try? await DuplicateCheck.card(for: text, among: cards)
            }
            if let answer, let existing = words.first(where: { $0.id == answer }) {
                redirected = text
                become(word, existing)
                return nil
            }
        }
        redirected = nil
        // Whatever was typed, AI decides the headword: the card types it out when it comes.
        lexicographer.write(word)
        return word
    }

    /// The card just added for what was typed turns into `existing`, the card the wall has for that word already: it
    /// takes on that card's word, entry, picture and how well it is remembered, there at the top where it went up,
    /// and they come in on it as on any new card, quickly (`Lexicographer.replay`); the old card leaves its place as a
    /// deleted card does. A card whose picture is still being drawn goes up to the top itself instead, the new one
    /// making way, so the picture lands on it.
    private func become(_ word: Word, _ existing: Word) {
        guard word.id != existing.id else { return }
        if Illustrator.shared.isDrawing(existing) {
            withAnimation(.smooth(duration: 0.45)) {
                lexicographer.forgetGeneration(for: word.id)
                existing.createdAt = word.createdAt
                Chats.shared.forget(word.id.uuidString)
                context.delete(word)
            }
            try? context.save()
            show(existing.id)
            return
        }
        let typed = lexicographer.generation(for: word)?.placeholder ?? word.request ?? word.text
        word.text = existing.text
        word.request = existing.request
        word.entryData = existing.entryData
        word.imageData = existing.imageData
        word.recallData = existing.recallData
        word.sentence = existing.sentence
        word.source = existing.source
        try? context.save()
        Chats.shared.move(existing.id.uuidString, to: word.id.uuidString)
        lexicographer.replay(word, typed: typed)
        remove([existing], after: .zero)
    }

    #if DEBUG
    /// Launch arguments for checking how generation looks: `-openWord <word>` opens the word's page; `-rehearseDrawing
    /// <word> [-rehearseDelay s] [-rehearseWait s]` plays a drawing of a stored word for free; `-addWord <text>
    /// [-openAfterAdd YES]` adds a word as if typed (it costs what a real word costs), opening its page at once.
    private static func firstTextField(in view: UIView?) -> UITextField? {
        guard let view else { return nil }
        if let field = view as? UITextField { return field }
        for sub in view.subviews { if let field = firstTextField(in: sub) { return field } }
        return nil
    }

    private func debugLaunch() async {
        // For checking how drawing looks without paying for one: `-openWord <word>` opens the word's page, and
        // `-rehearseDrawing <word> -rehearseDelay <seconds>` plays a drawing of a stored word.
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "openWord"), let word = words.first(where: { $0.text == name }) {
            path = [word]
        }
        // `-grantPoints <n>` gives the account n points, from a local server (`-serverURL`) that allows it.
        let granted = defaults.double(forKey: "grantPoints")
        if granted != 0, let request = try? CueServer.request("v1/dev/grant", json: ["points": granted], timeout: 10),
           let (_, response) = try? await URLSession.shared.data(for: request) {
            try? CueServer.check(response)
        }
        // `-openReview YES` opens review; `-openAI YES`, the wall's conversation.
        if defaults.bool(forKey: "openReview") { showingReview = true }
        if defaults.bool(forKey: "openAI") { showingAI = true }
        // `-keyboardLoop <n>` brings the keyboard up and puts it away n times, for profiling it on the phone.
        let loops = defaults.integer(forKey: "keyboardLoop")
        if loops > 0 {
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<loops {
                WallLog.note("loop: focus")
                Self.firstTextField(in: UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)?
                    .becomeFirstResponder()
                try? await Task.sleep(for: .seconds(1.5))
                WallLog.note("loop: resign")
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        if let name = defaults.string(forKey: "rehearseDrawing"), let word = words.first(where: { $0.text == name }) {
            // Launch arguments arrive as strings; `double(forKey:)` reads them, and 0 means absent.
            let delay = defaults.double(forKey: "rehearseDelay"), wait = defaults.double(forKey: "rehearseWait")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
            Illustrator.shared.rehearse(word, taking: .seconds(wait > 0 ? wait : 12))
        }
        // `-rehearseEntry <word>` plays a new word's writing for a stored word, for free: its headword, meaning and
        // description arrive one after another, then its picture. `-rehearseAs <text>` plays it as if that was typed.
        if let name = defaults.string(forKey: "rehearseEntry"), let word = words.first(where: { $0.text == name }) {
            let delay = defaults.double(forKey: "rehearseDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
            Lexicographer.shared.rehearse(word, as: defaults.string(forKey: "rehearseAs"))
        }
        // `-insertWord <text>` puts a finished card on the wall under that name (a copy of the first finished word's
        // entry and picture), without asking AI anything now or on the next launch, to watch the wall make room.
        if let text = defaults.string(forKey: "insertWord"),
           let model = words.first(where: { $0.entry?.isFinal == true && $0.imageData != nil }) {
            try? await Task.sleep(for: .seconds(3))
            let word = Word(text: text, entry: model.entry)
            word.imageData = model.imageData
            context.insert(word)
            try? context.save()
            revealTarget = word.id
        }
        // `-insertEntry <file> -insertAs <headword> [-insertRequest <typed>]` puts a card with the entry in that JSON file
        // (in Documents) and no picture on the wall, as one still waiting for its picture, and draws it: to check
        // drawing from a brief the safety system turned down (it costs what the pictures cost). A file, since a launch
        // argument that starts with "{" is read as a property list.
        if let file = defaults.string(forKey: "insertEntry"), let text = defaults.string(forKey: "insertAs"),
           let json = try? Data(contentsOf: URL.documentsDirectory.appending(path: file)),
           let entry = try? JSONDecoder().decode(WordEntry.self, from: json) {
            try? await Task.sleep(for: .seconds(3))
            let word = Word(text: text, entry: entry)
            word.request = defaults.string(forKey: "insertRequest")
            context.insert(word)
            try? context.save()
            revealTarget = word.id
            Illustrator.shared.draw(word)
        }
        // `-rewriteBrief <brief> -rewriteFor <headword> [-rewriteTimes n]` asks for a brief to pass the safety system n
        // times, as after a picture turned down for what came out, and writes the answers to Documents/briefs.txt, for
        // tuning that question (a fraction of a cent each).
        if let brief = defaults.string(forKey: "rewriteBrief"), let headword = defaults.string(forKey: "rewriteFor") {
            let refusal = #"{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","code":"moderation_blocked","moderation_details":{"moderation_stage":"output","categories":["other"]}}}"#
            var lines: [String] = []
            for _ in 0..<max(defaults.integer(forKey: "rewriteTimes"), 1) {
                do {
                    lines.append(try await EntryGenerator.saferPictureIdea(brief, for: headword, meaning: nil, refusal: refusal))
                } catch {
                    lines.append("error: \(error.localizedDescription)")
                }
            }
            try? lines.joined(separator: "\n")
                .write(to: URL.documentsDirectory.appending(path: "briefs.txt"), atomically: true, encoding: .utf8)
        }
        // `-removeWord <text>` fades a card out and removes it, as deleting it from its page does, to watch it leave.
        if let text = defaults.string(forKey: "removeWord"), let word = words.first(where: { $0.text == text }) {
            try? await Task.sleep(for: .seconds(3))
            remove([word], after: .zero)
        }
        // `-checkDuplicates "雨伞|dog"` asks `DuplicateCheck` about each input, one after another, and writes its
        // answers to Documents/duplicates.txt, for tuning its question (a fraction of a cent).
        if let list = defaults.string(forKey: "checkDuplicates") {
            var lines: [String] = []
            for input in list.split(separator: "|").map(String.init) {
                let start = Date.now
                do {
                    if let answer = try await DuplicateCheck.ask(input, among: writtenCards) {
                        let top = answer.probabilities.prefix(3)
                            .map { "\($0.value) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
                        let ms = Int(Date.now.timeIntervalSince(start) * 1000)
                        lines.append("\(input) → \(answer.choice) · confidence \(String(format: "%.2f", answer.confidence)) · [\(top)] · \(ms) ms")
                    }
                } catch {
                    lines.append("\(input) → error: \(error.localizedDescription)")
                }
            }
            try? lines.joined(separator: "\n")
                .write(to: URL.documentsDirectory.appending(path: "duplicates.txt"), atomically: true, encoding: .utf8)
        }
        // `-writeEntries "酸菜鱼|sleep on it"` writes each entry as a new word's is written, without adding a card or
        // drawing anything, into Documents/entries.txt, for checking the prompt (it costs what an entry costs).
        if let list = defaults.string(forKey: "writeEntries") {
            var lines: [String] = []
            for input in list.split(separator: "|").map(String.init) {
                do {
                    let (headword, entry) = try await EntryGenerator.entry(for: input)
                    lines.append("■ \(input) → \(headword)  |  \(entry.summary)  |  ipa: \(entry.phoneticUS ?? "—")")
                    for part in entry.parts {
                        let senses = part.senses.map { "\($0.chinese): \($0.english ?? "")" }.joined(separator: " / ")
                        lines.append("  [\(part.pos)] \(senses)")
                    }
                    for line in entry.exchange ?? [] {
                        lines.append("  — \(line.english)  \(line.chinese)")
                    }
                    let phrases = (entry.collocations ?? []).map { "\($0.phrase) (\($0.chinese))" }
                    lines.append("  phrases: \(phrases.isEmpty ? "—" : phrases.joined(separator: "; "))")
                    lines.append("  usage: \(entry.note ?? "—")")
                    lines.append("  origin: \(entry.etymology ?? "—")")
                    lines.append("  asked: \(entry.question ?? "—")")
                } catch {
                    lines.append("■ \(input) → error: \(error.localizedDescription)")
                }
            }
            try? lines.joined(separator: "\n")
                .write(to: URL.documentsDirectory.appending(path: "entries.txt"), atomically: true, encoding: .utf8)
        }
        // `-addWord <text>` adds a word as if typed, for a real run without the simulator's slow taps (it costs
        // what a real word costs).
        if let text = defaults.string(forKey: "addWord") {
            try? await Task.sleep(for: .seconds(3))
            // `-openAfterAdd YES` opens the new word's page at once, to watch its entry stream in.
            if let word = await add(text), defaults.bool(forKey: "openAfterAdd") { path = [word] }
        }
    }
    #else
    private func debugLaunch() async {}
    #endif

    /// Picks up cards still waiting for AI (the user's own words, or an entry without its picture yet) and pictures
    /// that never got drawn: after a relaunch, or once a key has been added in Settings. Cards already being worked
    /// on, or with no key, are skipped by `write` and `draw`.
    private func resumePending() {
        for word in words where !(word.entry?.isFinal ?? false) {
            lexicographer.write(word)
        }
        for word in words where word.imageData == nil {
            Illustrator.shared.draw(word)
        }
    }

    /// Shows a card already on the wall for what was typed: scrolled into view, then pressed once, lightly, as a tap
    /// presses it.
    private func show(_ id: UUID) {
        revealTarget = id
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.spring(duration: 0.2)) { nudged = id }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(duration: 0.35)) { nudged = nil }
        }
    }

    /// Cards leave in two beats: they fade away where they stand, a touch smaller and blurred, all together, and the
    /// wall then closes the gaps at once on its own spring. `delay` lets whatever led here (a page zooming back into
    /// its card) finish first. A card's menu's Delete doesn't come here: the menu dissolves the card itself.
    private func remove(_ doomed: [Word], after delay: Duration) {
        let ids = Set(doomed.map(\.id))
        Task {
            try? await Task.sleep(for: delay)
            withAnimation(.smooth(duration: 0.3)) { leaving.formUnion(ids) }
            try? await Task.sleep(for: .milliseconds(240))
            for word in doomed {
                Chats.shared.forget(word.id.uuidString)
                context.delete(word)
            }
            try? context.save()
            leaving.subtract(ids)
            // A card still being written kept its last look while it faded; what was coming in for it goes now.
            for id in ids { lexicographer.forgetGeneration(for: id) }
        }
    }

    // MARK: Picking cards

    /// The wall picks cards to delete together: a round check on every card, a tap picks one or puts it back, and the
    /// bar below says how many and offers Delete (user, 2026-10-07: "批量删除").
    private func startSelecting() {
        withAnimation(.smooth(duration: 0.35)) { selection = [] }
    }

    private func endSelecting() {
        withAnimation(.smooth(duration: 0.35)) {
            selection = nil
            confirmingDelete = false
        }
    }

    private func toggle(_ word: Word) {
        guard var picked = selection else { return }
        if picked.remove(word.id) == nil { picked.insert(word.id) }
        withAnimation(.smooth(duration: 0.25)) { selection = picked }
    }

    /// A slide across the cards, as in Photos: from the card it starts on to the card under the finger, in reading
    /// order, every card is picked, or put back if the first card was already picked; cards the slide leaves again go
    /// back to how they were.
    private func slide(_ phase: SlidePhase) {
        let words = visibleWords
        switch phase {
        case .began(let index):
            guard let picked = selection, words.indices.contains(index) else { return }
            sliding = Slide(anchor: index, picks: !picked.contains(words[index].id), before: picked)
            slide(.moved(index))
        case .moved(let index):
            guard let sliding, !words.isEmpty else { return }
            let reach = min(max(index, 0), words.count - 1)
            var picked = sliding.before
            for word in words[min(sliding.anchor, reach)...max(sliding.anchor, reach)] {
                if sliding.picks { picked.insert(word.id) } else { picked.remove(word.id) }
            }
            if picked != selection { withAnimation(.smooth(duration: 0.2)) { selection = picked } }
        case .ended:
            sliding = nil
        }
    }

    /// The picked cards leave together, as a card deleted from its page does, once the bar's Delete is confirmed.
    private func deleteSelected() {
        guard let picked = selection else { return }
        let doomed = visibleWords.filter { picked.contains($0.id) }
        endSelecting()
        remove(doomed, after: .zero)
    }

    /// Scrolls the card into view: a card on the wall's first row to the top of the screen, one on its last row to the
    /// bottom, and those between as far down the screen as their row is down the wall, which are always places the
    /// wall can scroll to, with the card whole. The card itself comes in with the wall's own animation, and the others
    /// slide to make room, which is all the eye needs: a bounce on top of that was dropped on 2026-10-06.
    ///
    /// Centred, a card on the first row asked for the wall to be pulled further down than its top (with the keyboard
    /// up, by about 60 pt), and once the wall stayed there, a strip of empty wall over the cards (user, 2026-10-08:
    /// "上面…多出来了一块，很奇怪吧"). Scrolled by as little as shows the card, the wall also moved 15 pt sideways, where
    /// it stayed, as it can't be scrolled sideways back.
    private func reveal(_ id: UUID, with proxy: ScrollViewProxy) {
        guard let index = visibleWords.firstIndex(where: { $0.id == id }) else { return }
        let rows = (visibleWords.count + 1) / 2
        let place = rows > 1 ? Double(index / 2) / Double(rows - 1) : 0
        withAnimation(.smooth) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: place)) }
    }
}

/// The empty wall: the system's own empty state, with two cards for its symbol, the shape of the wall's own (user,
/// 2026-10-07: "用系统的，配卡片图标"). Tried first and turned down: a picture drawn for it, then type alone with its words
/// coming in one after another.
struct EmptyWall: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Words Yet", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
        } description: {
            // Broken where it reads well: left to wrap, it left "say, below." alone on a second line.
            Text("Type a word, or anything\nyou want to say, below.")
        }
        .allowsHitTesting(false)
    }
}

/// The round check a card wears while the wall is picking cards: empty until the card is picked, then filled in the
/// text's own colour, black (white in dark mode), with the check cut out of it, never the system's blue (user,
/// 2026-10-07). In the card's bottom-trailing corner as in Photos (a title can run the card's full width at the top).
struct SelectionCheck: View {
    var selected: Bool
    /// The card's size against Siri's 179 pt card.
    var scale: CGFloat

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary), AnyShapeStyle(.primary))
            .font(.system(size: 22 * scale))
            // Picked and put back at once. The symbol's replace effect took the check away first and the black after
            // it, in a blink (user, 2026-10-08: "对勾先消失，然后这个黑色立刻消失…选中和不选中的时候都不要有对勾出现和
            // 消失的动画").
            .animation(nil, value: selected)
            .padding(14 * scale)
    }
}

/// A card leaving the wall: a touch smaller, blurred and fading, where it stands.
struct LeavingEffect: ViewModifier {
    var gone: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(gone ? 0.86 : 1)
            .blur(radius: gone ? 12 : 0)
            .opacity(gone ? 0 : 1)
    }
}

/// Two columns of equal-size cards in level rows, filled left to right. The right column used to start lower, as in
/// Siri, where that cleared the floating button in the top corner; with the button in the navigation bar the offset
/// had nothing left to clear. The cards grow with the screen; the gaps do not.
struct CardGrid<Item: Identifiable, Content: View>: View {
    var items: [Item]
    var spacing: CGFloat
    /// Cards on their way out, which fade where they stand before the wall closes the gap. Given as data, not read
    /// inside `content`: a change read only there never redrew the grid, and the card never faded.
    var leaving: Set<Item.ID> = []
    /// A card being shown for what was typed, pressed once lightly; given as data for the same reason.
    var nudged: Item.ID? = nil
    /// While the wall is picking cards, the ones picked so far (nil otherwise), so each card can show whether it is:
    /// given as data for the same reason as `leaving`.
    var selection: Set<Item.ID>? = nil
    /// A slide across the cards while picking, by the index of the card under the finger.
    var onSlide: (SlidePhase) -> Void = { _ in }
    @ViewBuilder var content: (Item, _ cardWidth: CGFloat, _ selected: Bool?) -> Content

    @State private var width: CGFloat = 0

    private var cardWidth: CGFloat { max((width - spacing) / 2, 0) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible())], spacing: spacing) {
            ForEach(items) { item in
                let gone = leaving.contains(item.id)
                content(item, cardWidth, selection.map { $0.contains(item.id) })
                    .scaleEffect(nudged == item.id ? 0.96 : 1)
                    .modifier(LeavingEffect(gone: gone))
                    .allowsHitTesting(!gone)
                    // A new card blurs in. A card that goes is gone at once: by then it has faded away itself, or its
                    // menu is dissolving it (a removal transition kept it on the wall, and the menu's copy of it with
                    // it).
                    .transition(AnyTransition.asymmetric(insertion: AnyTransition(.blurReplace), removal: .identity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(SlideToSelect(isEnabled: selection != nil, index: index(at:), onSlide: onSlide))
        // A new card comes in the way the system brings things in, and the others slide to make room.
        .animation(.smooth(duration: 0.5), value: items.map(\.id))
    }

    /// The card under a point of the grid, or the nearest one: two columns of equal cards in rows `spacing` apart.
    private func index(at point: CGPoint) -> Int? {
        guard cardWidth > 0, !items.isEmpty else { return nil }
        let row = Int(((point.y + spacing / 2) / (cardWidth / CardMetrics.aspect + spacing)).rounded(.down))
        let column = point.x < cardWidth + spacing / 2 ? 0 : 1
        return min(max(row * 2 + column, 0), items.count - 1)
    }
}

enum SlidePhase {
    case began(Int)
    case moved(Int)
    case ended
}

/// A finger sliding across the cards while the wall is picking them. A slide that starts sideways picks; one that
/// starts up or down scrolls as ever, the wall's scrolling waiting that long to know which it is. Held near the top or
/// bottom of the screen, a picking slide scrolls the wall on, faster the nearer the edge, picking as it goes.
struct SlideToSelect: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The card under a point of the grid.
    var index: (CGPoint) -> Int?
    var onSlide: (SlidePhase) -> Void

    final class Coordinator: NSObject {
        weak var recognizer: SidewaysPan?
        weak var scrollView: UIScrollView?
        /// Where the grid starts in the scroll view's content.
        var origin: CGPoint = .zero
        var index: (CGPoint) -> Int? = { _ in nil }
        var onSlide: (SlidePhase) -> Void = { _ in }
        private var link: CADisplayLink?

        func follow() {
            link?.invalidate()
            link = CADisplayLink(target: self, selector: #selector(step))
            link?.add(to: .main, forMode: .common)
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        /// Scrolls on while the finger is held in the top or bottom band of the screen, and picks what comes under it.
        @objc private func step(_ link: CADisplayLink) {
            guard let recognizer, let scrollView else { return }
            let band: CGFloat = 80, fastest: CGFloat = 900
            let inset = scrollView.adjustedContentInset
            let y = recognizer.location(in: scrollView).y - scrollView.contentOffset.y
            let top = inset.top + band, bottom = scrollView.bounds.height - inset.bottom - band
            let pull = y < top ? -min((top - y) / band, 1) : y > bottom ? min((y - bottom) / band, 1) : 0
            guard pull != 0 else { return }
            let lowest = -inset.top
            let highest = max(scrollView.contentSize.height + inset.bottom - scrollView.bounds.height, lowest)
            let offset = min(max(scrollView.contentOffset.y + pull * fastest * (link.targetTimestamp - link.timestamp),
                                 lowest), highest)
            guard offset != scrollView.contentOffset.y else { return }
            scrollView.contentOffset.y = offset
            let point = recognizer.location(in: scrollView)
            if let index = index(CGPoint(x: point.x - origin.x, y: point.y - origin.y)) { onSlide(.moved(index)) }
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> SidewaysPan {
        let pan = SidewaysPan()
        pan.maximumNumberOfTouches = 1
        context.coordinator.recognizer = pan
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: SidewaysPan, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.index = index
        context.coordinator.onSlide = onSlide
    }

    func handleUIGestureRecognizerAction(_ recognizer: SidewaysPan, context: Context) {
        let coordinator = context.coordinator
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began:
            coordinator.scrollView = recognizer.enclosingScrollView
            if let scrollView = coordinator.scrollView {
                let inContent = recognizer.location(in: scrollView)
                coordinator.origin = CGPoint(x: inContent.x - point.x, y: inContent.y - point.y)
                coordinator.follow()
            }
            if let index = index(point) { onSlide(.began(index)) }
        case .changed:
            if let index = index(point) { onSlide(.moved(index)) }
        case .ended, .cancelled, .failed:
            coordinator.stop()
            onSlide(.ended)
        default:
            break
        }
    }
}

/// A one-finger pan that only begins sideways: up or down, it gives way at once, and the scroll view it sits in
/// waits for it to.
final class SidewaysPan: UIPanGestureRecognizer {
    private var start: CGPoint?

    /// The scroll view the touch is in.
    var enclosingScrollView: UIScrollView? {
        var view = self.view
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        guard let window = self.view?.window else { return nil }
        var hit = window.hitTest(location(in: window), with: nil)
        while let current = hit {
            if let scrollView = current as? UIScrollView { return scrollView }
            hit = current.superview
        }
        return nil
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        if other is UIPanGestureRecognizer, other.view is UIScrollView { return true }
        return super.shouldBeRequiredToFail(by: other)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first.map { $0.location(in: nil) }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let point = touches.first?.location(in: nil) {
            let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
            if max(dx, dy) > 8, dy > dx {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        start = nil
        super.reset()
    }
}

/// The bottom bar of the wall, sized and placed like the system's bottom search field and Siri's corner buttons.
/// At rest: Review, the long glass field and AI. While typing, the field widens over Review's place and a Close circle
/// takes AI's, as Messages swaps in its close button when search starts. Return adds what was typed, and the keyboard
/// stays up for the next word.
struct InputBar: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onReview: () -> Void
    var onAI: () -> Void
    /// Told just before the field takes the keyboard, whose coming then holds the main thread.
    var onBeginEditing: () -> Void = {}
    /// Whether the field has the keyboard.
    @State private var focused = false
    /// Follows `focused` inside an animation of its own. Left to the keyboard's timing, Review vanished in a single
    /// frame on the way in, and on the way out it sometimes grew out of the field and slid across its placeholder.
    @State private var typing = false
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: WallMetrics.barSpacing) {
            HStack(spacing: WallMetrics.barSpacing) {
                entryBar
            }
            .frame(height: WallMetrics.barHeight)
            // The whole bar takes taps, so none falls through to a card behind.
            .contentShape(.rect)
        }
        .padding(.horizontal, typing ? WallMetrics.barInsetOverKeyboard : WallMetrics.barInset)
        // Where the bar stands is `KeyboardRidingBar`'s doing: resting, it reaches into the home indicator's safe area
        // like the system's (34 pt there, 27.5 pt from the screen's edge); over the keyboard it sits 8 pt above the
        // keys, and goes from the one to the other with the keyboard.
        .onChange(of: focused) {
            WallLog.note("focused \(focused)")
            withAnimation(.smooth) { typing = focused }
        }
    }

    /// Review, the field, and AI; while typing, the field and Close.
    @ViewBuilder
    private var entryBar: some View {
        if !typing {
            circle("rectangle.stack", label: "Review", id: "review", action: onReview)
        }
        WordField(placeholder: String(localized: "Add a word"), text: $text, focused: $focused, onSubmit: onSubmit,
                  onBeginEditing: onBeginEditing)
            .padding(.horizontal, 20)
            .frame(height: WallMetrics.barHeight)
            // The whole capsule takes the tap, so a tap near its edge can't fall through to a card behind.
            .contentShape(.capsule)
            .onTapGesture { focused = true }
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("field", in: glass)
        if typing {
            circle("xmark", label: "Close", id: "close") {
                text = ""
                focused = false
            }
        } else {
            circle("sparkles", label: "Ask AI", id: "ai", action: onAI)
        }
    }

    /// A 48 pt glass circle, the height of the field, like the circle Messages shows beside its search field.
    private func circle(_ symbol: String, label: LocalizedStringKey, id: String,
                        style: AnyShapeStyle = AnyShapeStyle(.primary), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleFace(symbol, id: id, style: style)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func circleFace(_ symbol: String, id: String, style: AnyShapeStyle = AnyShapeStyle(.primary)) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(style)
            .frame(width: WallMetrics.barHeight, height: WallMetrics.barHeight)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID(id, in: glass)
            // Circles fade in and out where they stand, the way the user liked best, instead of growing out of
            // the field or being swallowed by it.
            .glassEffectTransition(.materialize)
    }
}

/// The wall's UIKit scroll view, and what carries its glide through the keyboard's coming, kept out of the view's state.
private final class WallScroll {
    weak var view: UIScrollView?
    var carrier: GlideCarrier?

    func found(_ scrollView: UIScrollView) {
        guard scrollView !== view else { return }
        view = scrollView
        carrier = GlideCarrier(scrollView)
    }
}

/// The room the wall keeps under its last cards for the home indicator, the bar, and the keyboard while it is up: the
/// bar's height and its gap over the keys, the same with the keyboard up or away (at rest the bar sits 14.5 pt lower,
/// in the home indicator's room, and the last cards simply end that much higher). A fixed room never changes under a
/// finger, and costs nothing as the keyboard moves: following the keyboard frame by frame, it redrew the wall's inset
/// on every frame of the keyboard's way (measured on the phone, 2026-10-09: 12–14 ms of the main thread a frame as the
/// keyboard went down, against a budget of 8).
private struct BarRoom: View {
    var keyboard: KeyboardRoom

    var body: some View {
        Color.clear.frame(height: WallMetrics.homeIndicator + keyboard.room + WallMetrics.barHeight
                          + WallMetrics.barInsetOverKeyboard)
    }
}

/// How far the keyboard reaches above the home indicator, while the wall makes room for it: read by `BarRoom` alone, so
/// the room changing as the keyboard comes and goes redraws the room, not the wall. Redrawn, the wall took ~35 ms of the
/// phone's main thread (2026-10-09) just as the keyboard's coming held it for ~150.
@Observable
private final class KeyboardRoom {
    var room: CGFloat = 0
}

/// The field words are added through: UIKit's, so that Return adds what was typed and the keyboard simply stays up
/// for the next word (user, 2026-10-07: "发出去了之后，键盘应该不自己收起来…才能方便我这个持续的输入新的单词"), on the
/// keyboard's own return key rather than a check mark ("我们把回车当成输入来用就可以了，而不是这个对勾"). SwiftUI's field
/// ends its editing on Return, and taking the focus back at once brought the keyboard down and up again ("它会掉下去一下，
/// 然后再上来一下"). The caret is in the text's own colour, black (white in dark mode), never the system's blue.
struct WordField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void
    var onBeginEditing: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.tintColor = .label
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .default
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Words being composed (pinyin, say) aren't the field's text yet: left alone until they are.
        if field.markedTextRange == nil, field.text != text { field.text = text }
        if focused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !focused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WordField
        #if DEBUG
        private var stalled = Date.distantPast
        #endif

        init(_ parent: WordField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            parent.text = field.text ?? ""
        }

        /// Adds the word and keeps the keyboard.
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.text = field.text ?? ""
            parent.onSubmit()
            return false
        }

        func textFieldShouldBeginEditing(_ field: UITextField) -> Bool {
            parent.onBeginEditing()
            #if DEBUG
            // `-stallKeyboard <ms>` holds the main thread as the keyboard comes, as long as it is held on the phone, for
            // checking in the simulator what a glide does meanwhile.
            let stall = UserDefaults.standard.double(forKey: "stallKeyboard")
            if stall > 0, !field.isFirstResponder, Date.now.timeIntervalSince(stalled) > 1 {
                stalled = .now
                usleep(useconds_t(stall * 1000))
            }
            #endif
            return true
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.focused { parent.focused = false }
        }
    }
}
