import SwiftData
import SwiftUI

/// AI to talk to, as long as the user likes: about the whole wall, from its AI button, or about one word, from that
/// word's page (user, 2026-10-07: "就跟ChatGPT一样…可以长聊天的…基于这个单词…问一些follow up的问题…基于整个单词库…
/// 问一些general的问题…组成一个段落…情景对话"). One conversation per place, kept until the user starts it over (`Chats`).
/// The user's questions sit on the right; AI's answers run the width of the page, set as the word page sets mixed
/// text: Chinese in the body font, English in serif, which reads itself aloud when tapped.
///
/// A question goes up to the top of the screen as it is sent, and the answer is written under it, the conversation
/// not following it down: an answer can be read from its first line however fast it comes, as in ChatGPT's and
/// Claude's apps since 2025 (user, 2026-10-07: "刚发消息的时候，这个消息到底是在下面还是在上面"). Messengers keep the
/// newest at the bottom, where their short messages matter most; here answers run to paragraphs.
struct ChatView: View {
    /// What the conversation is about.
    enum Topic {
        case wall
        case word(Word)
    }

    let topic: Topic
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Word.createdAt, order: .reverse) private var words: [Word]
    /// Whether the field has the keyboard (`ChatBar`'s focus, kept here).
    @State private var focused = false
    @State private var position = ScrollPosition(idType: Chat.Message.ID.self)
    /// The question last asked since the conversation was opened. It and what follows take at least a screen, room
    /// for the question to be lifted to the top however short its answer, and keep it after the answer is in, so the
    /// question stays at the top until the next one is asked, as in ChatGPT's and Claude's apps (user, 2026-10-09: "好像
    /// 应该是把问题留在顶部才是更合理的，其他AI都这么干"). The room went for a while once the answer was in, the
    /// conversation coming down until the answer ended over the bar ("下面空档太大了吧"): what was being read moved by
    /// itself. A conversation opened again opens at the end of what was written.
    @State private var asked: Chat.Message.ID?
    /// What stands between a question and AI: agreeing to it, points, or a key.
    @State private var gate: AIGate?
    /// The word an answer offered that waits with the gate, tapped while it stood (`keep`); none while a question waits.
    @State private var gatedOffer: String?
    /// The offered words tapped since the conversation was opened, as compared (`EntryStyle.key`): ticked at the tap,
    /// before their cards are in.
    @State private var keeping: Set<String> = []
    /// Puts a word on the wall as if it had been typed there: the wall's, which the conversation was opened from.
    @Environment(\.keepOnWall) private var keepOnWall
    /// The deck an answer handed over that is being reviewed (`DeckCapsule`).
    @State private var reviewing: Chat.Deck?
    /// Where what is kept on a word's page from its conversation is saved.
    @Environment(\.modelContext) private var modelContext
    /// Whether the keyboard is going as a question is asked: the question goes up to the top with it (`riseWithKeyboard`).
    @State private var risesWithKeyboard = false
    /// Whether the conversation is laid out: from just after the page began to come up (`onAppear`).
    @State private var shown = false
    /// How far below the top of the screen the conversation's content begins: under the status and navigation bars.
    @State private var top: CGFloat = 0
    /// How tall the question last asked and what follows it are, without the room kept under them.
    @State private var latest: CGFloat = 0
    /// Whether the conversation is scrolled to its end.
    @State private var atEnd = false
    /// Whether a finger is on the conversation, or it is still gliding from one.
    @State private var touched = false
    /// Whether the keyboard is up; how far it reaches above the home indicator while the conversation makes room for
    /// it, set as the keyboard comes and goes, never as it moves; whether a finger or a glide moves the conversation;
    /// and whether the keyboard is going.
    @State private var keyboardUp = false
    @State private var keyboardRoom: CGFloat = 0
    /// The keyboard's room as the room kept under the question last asked has made way for it, an update apart from
    /// `keyboardRoom` (`setKeyboardRoom`).
    @State private var roomKeyboard: CGFloat = 0
    @State private var moving = false
    @State private var keyboardGoing = false
    /// The input bar's height: taller as a question runs on to more lines.
    @State private var barHeight = WallMetrics.barHeight
    /// The conversation's scroll view and what moving it with the keyboard needs, kept out of the view's state.
    @State private var scrolled = Scrolled()
    /// Whether a finger is dragging the conversation.
    @State private var dragging = false
    /// Whether the conversation is following an answer down as it is written: the field took the focus while it was.
    @State private var following = false
    /// Whether the keyboard is on its way up: the conversation's end goes up with it.
    @State private var rising = false
    /// Whether the conversation's question to delete it is open.
    @State private var confirmingDelete = false
    /// Whether the conversation is scrolled more than a screen above its end.
    @State private var farFromEnd = false
    /// Whether the first question of the conversation is about to rise from the field: held down there for a frame.
    @State private var lifting = false
    /// When the conversation began to vanish, while it is being deleted (`vanish`).
    @State private var vanishing: Date?
    /// Answers' lines, set as they are once written (`SelectableText`), for the answers vanishing.
    @ScaledMetric(relativeTo: .body) private var lineHeight = SelectableText.lineHeight
    private let chats = Chats.shared

    private var key: String {
        switch topic {
        case .wall: Chats.wall
        case .word(let word): word.id.uuidString
        }
    }

    /// The word the conversation is about, if it is about one: its page keeps what the user chooses of the conversation.
    private var topicWord: Word? {
        if case .word(let word) = topic { word } else { nil }
    }

    private var title: String {
        switch topic {
        case .wall: String(localized: "Ask AI")
        case .word(let word): word.text
        }
    }

    /// What is being written: the conversation's, so it is still there when the conversation is opened again.
    private var draft: Binding<String> {
        Binding { chats.drafts[key] ?? "" } set: { chats.drafts[key] = $0 }
    }

    private var context: ChatContext {
        switch topic {
        case .wall: ChatPrompt.wall(words.filter { $0.entryData != nil })
        case .word(let word): ChatPrompt.word(word)
        }
    }

    var body: some View {
        let messages = chats.messages(in: key)
        let answering = chats.answering.contains(key)
        // Where the question last asked begins, if it was asked since the conversation was opened.
        let split = asked.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.endIndex
        // Whether there is a question asked since the conversation was opened, with its room under it.
        let kept = split < messages.endIndex
        // The words answers have offered that are on the wall or on their way to it, whose capsules show ticks: the
        // wall is read only with offers in the conversation, so it isn't laid out again each time a card is written.
        let onWall = messages.contains { $0.offers != nil } ? wallKeys.union(keeping) : keeping
        // The wall's cards, for the decks answers handed over: read only with a deck in the conversation; and what the
        // word's page keeps, for the notes answers offer.
        let wall = WallNow(keys: onWall, ids: messages.contains { $0.deck != nil } ? Set(words.map(\.id)) : [],
                           noted: Set(topicWord?.notes.map(\.id) ?? []))
        // Read out here, around everything, without the keyboard: the screen, which doesn't change as the keyboard
        // moves. The keyboard is `keyboardRoom`.
        GeometryReader { screen in
            // The room under the question last asked: the screen between the bars, keyboard and all. It grows and
            // shrinks as the keyboard goes and comes, so the question stays where it is.
            let room = screen.size.height + screen.safeAreaInsets.top - top - 2 * Self.margin - WallMetrics.barHeight
                - Self.barBottom(keyboardRoom: roomKeyboard)
            let _ = scrolled.note(room: kept ? room : nil, latest: latest)
            let screenTop = screen.safeAreaInsets.top
            NavigationStack {
                ScrollView {
                    if shown { transcript(messages, answering: answering, split: split, room: room, wall: wall) }
                }
                .contentMargins(.horizontal, Self.side, for: .scrollContent)
                // Under the navigation bar in margins of its own, not the safe area: SwiftUI keeps a scroll view's
                // insets to about 60% of its height by taking from its safe area, so with the room for the emoji keys
                // (taller than the letters') it took the bar's 53 pt away, and the conversation went up under the bar
                // by as much (iOS 27; on the phone the letters' room leaves it just under that).
                .contentMargins(.top, top + Self.margin, for: .scrollContent)
                .contentMargins(.top, top, for: .scrollIndicators)
                .ignoresSafeArea(edges: .top)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
                    // Where the navigation bar ends. While the keyboard is up SwiftUI takes from it, all of it with the emoji
                    // keys and a little more or less on every frame of a keyboard dragged down, and then only a larger
                    // value is the bar's own. Followed, each change laid the page out again, which changed it again, some
                    // sixty times in one frame (measured in the simulator, 2026-10-09): the conversation and the keyboard
                    // stopped under the finger for up to 180 ms on the phone, and the empty page's placeholder jumped
                    // (user's recording, 2026-10-09 20:24).
                    guard inset > screenTop + 30 else { return }
                    if !keyboardUp || inset > top { top = inset }
                }
                // The conversation's own room under its end: the home indicator's, the bar's, and the keyboard's while
                // it is up, as the wall keeps its own (`BarRoom`). Left to SwiftUI, the conversation was laid out again
                // on every frame of a keyboard dragged down by the finger, and the bar, on the screen's safe area,
                // followed the keys on a curve of its own (user, 2026-10-09, after the wall had been made so: "aichat页面
                // 还是不行").
                .contentMargins(.bottom, Self.margin + bottomRoom, for: .scrollContent)
                .contentMargins(.bottom, bottomRoom, for: .scrollIndicators)
                .scrollPosition($position)
                .scrollTargetBehavior(GlideTargetReader { scrolled.carrier })
                // Growing, it keeps its place, so an answer is written on below what is being read. At its end with
                // nothing being written, the conversation goes up and down with the keyboard and the bar, its end
                // kept just over them, as a messenger's does, and so it does while the keyboard comes up; and it keeps
                // the end in sight as it grows while it follows an answer down. Not while a finger is on it: moving
                // under the finger, it shook. (Not `defaultScrollAnchor(.bottom, for: .initialOffset)` to open at the
                // end: until the conversation was scrolled by hand, that kept its end in sight as it grew, so it
                // followed the first answer down after all.) Not while the room kept under the question last asked
                // holds more than the question and its answer: that room then grows and shrinks as the keyboard's does,
                // so the conversation is to stay where it is.
                .defaultScrollAnchor(!(kept && latest < room)
                                         && (following || rising || (atEnd && !answering && !touched)) ? .bottom : .top,
                                     for: .sizeChanges)
                .onScrollGeometryChange(for: Ends.self) { geometry in
                    // In the content's own space: how far the conversation can scroll.
                    let end = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.height
                    return Ends(atEnd: geometry.contentOffset.y >= end - 10,
                                far: end - geometry.contentOffset.y > geometry.visibleRect.height)
                } action: { _, ends in
                    atEnd = ends.atEnd
                    farFromEnd = ends.far
                }
                .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentInsets.bottom, $0.contentSize.height] } action: { _, v in
                    WallLog.note(String(format: "chat geo offset %.1f bottom %.1f content %.1f", v[0], v[1], v[2]))
                }
                .onScrollPhaseChange { old, phase in
                    WallLog.note("chat phase \(old) -> \(phase)")
                    touched = phase == .tracking || phase == .interacting || phase == .decelerating
                    dragging = phase == .interacting
                    moving = phase != .idle
                    if phase == .interacting && old != .interacting {
                        scrolled.carrier?.drop()
                        // A finger on the conversation stops it following an answer down.
                        following = false
                    }
                    // Let go of as the keyboard goes down: on through the hold its putting away makes
                    // (`carryRelease`), to rest short of where the end will be without its room, or down with the
                    // keyboard to that end. Left where the finger lets go of it, as any scroll view is: sent back to its
                    // end as the finger let go, a drag from there that put the keyboard down sprang back up, in the
                    // middle of the text (user, 2026-10-09: "我们下滑…处于这个文字中段的时候…它怎么可能是一个这样的回弹效果
                    // 呢？这太诡异了").
                    if old == .interacting && phase != .interacting, let scrollView = scrolled.scrollView {
                        scrolled.carrier?.carryRelease(end: end(of: scrollView, withKeyboardRoom: 0))
                    }
                    if keyboardGoing { giveUpKeyboardRoom() }
                }
                // The keyboard goes only when it is dragged down. A tap on the conversation put it down too, and so
                // did the touch that stops a scroll, so it fell as the conversation was read (user, 2026-10-08: "我发生
                // 滚动的行为，我这个键盘就会自动落下去。这也太敏感了吧").
                .scrollDismissesKeyboard(.interactively)
                // Fading out under the navigation bar as the wall and the word pages do (user, 2026-10-07: "我们正常页面的
                // 那个虚化，它是有这种progressive blur的这种效果的…这边的这个滚动它就没这个效果"). Under the input bar, as
                // under theirs, the conversation runs on behind the glass: a fade there is drawn by the scroll view where
                // its room ends, which can't follow a keyboard dragged down by the finger.
                .scrollEdgeEffectStyle(.soft, for: .top)
                // With nothing said yet, the empty conversation, as the empty wall shows itself (user, 2026-10-08:
                // "在没有内容的时候，它也应该有一个这个空白的这个占位，placeholder"), its name and symbol only: a line under
                // them on what to ask was too much ("占位的内容太多"). Over the conversation, between the bars and over the
                // keyboard; nothing in it to ask (suggestions were turned down: "不要有这些…提示").
                // Centred over the bar and the keyboard, and carried with them as the keyboard moves (`fillsAbove`):
                // centred in the conversation's room, it jumped by half the keyboard in a single frame as the room came
                // in.
                .overlay {
                    if messages.isEmpty {
                        KeyboardRidingBar(restingGap: WallMetrics.barInset - WallMetrics.homeIndicator
                                              + WallMetrics.barHeight + Self.margin,
                                          raisedGap: WallMetrics.barInsetOverKeyboard + WallMetrics.barHeight + Self.margin,
                                          fillsAbove: true, top: top + Self.margin) {
                            ContentUnavailableView("No Questions Yet", systemImage: "sparkles")
                        }
                        .ignoresSafeArea()
                        // Faded, not blurred in, as the empty wall is: around the container, `.blurReplace` or
                        // `.allowsHitTesting(false)` (it lets every touch through anyway) left its keyboard guide off the
                        // keyboard, so after a conversation was deleted the placeholder came in 57 pt low and jumped up
                        // as the transition ended (measured in the simulator, 2026-10-09).
                        .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.5), value: messages.isEmpty)
                // An answer being written is followed down once the field takes the focus.
                .onChange(of: focused) { _, focused in
                    guard focused else { return }
                    if answering { following = true }
                    rising = true
                    Task {
                        try? await Task.sleep(for: .seconds(0.6))
                        rising = false
                    }
                }
                // The keyboard coming up brings the end of the conversation up over it, wherever it was scrolled to,
                // going up with the keyboard, on its own curve (user, 2026-10-08: "键盘重新打开不在内容最下面，不好";
                // then "我升起的时候，它要过一会儿它才能…把正文的最底下交给我": the conversation set off after the
                // keyboard, on a slower curve of its own). The room comes in at once, under the keyboard before it has
                // moved, and the conversation goes to where its end will be with it, in the keyboard's own animation:
                // scrolled by SwiftUI, it stood still while the keyboard's coming held the main thread, then jumped.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification),
                           perform: keyboardWillShow)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification),
                           perform: keyboardWillHide)
                // No room at the bottom but the conversation's own: SwiftUI's, the home indicator's included, changed as
                // a dragged keyboard neared the bottom, and threw a conversation pulled past its top back up.
                .ignoresSafeArea(edges: .bottom)
                // The bar rides the keyboard itself (`KeyboardRidingBar`), as the wall's does.
                .overlay {
                    KeyboardRidingBar(restingGap: WallMetrics.barInset - WallMetrics.homeIndicator,
                                      raisedGap: WallMetrics.barInsetOverKeyboard,
                                      onTouch: { scrolled.carrier?.carry() }) {
                        ChatBar(text: draft, answering: answering, focused: $focused, height: $barHeight,
                                onSend: { send(draft.wrappedValue) }, onStop: { chats.stop(key) })
                    }
                    .ignoresSafeArea()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) { dismiss() }
                    }
                    // Delete, for the whole conversation (user, 2026-10-08: "为什么要弄个这个写字的按钮？…还不如弄个删除呢。
                    // 代表删除当时、当前聊天的一切"; a pen and paper, for starting a new chat, read as writing
                    // something). Always there, and greyed out with nothing to delete ("在无法删除的时候，那个删除按钮
                    // 应该还存在，只是无法点击而已"). It asks first, as deleting several cards does, the button opening
                    // into the question as Photos' does.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete Conversation", systemImage: "trash") { confirmingDelete = true }
                            .disabled(messages.isEmpty || vanishing != nil)
                            .confirmationDialog("Delete Conversation", isPresented: $confirmingDelete,
                                                titleVisibility: .hidden) {
                                Button("Delete Conversation", role: .destructive, action: vanish)
                            } message: {
                                Text("This conversation will be deleted.")
                            }
                    }
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // The caret in the text's own colour, never the system's blue.
        .tint(.primary)
        // A deck an answer handed over, reviewed on its own, coming up as review does from the wall's Review button. Not
        // zoomed out of its capsule: on the way back the page was squeezed into the capsule's shape, its card and the
        // capsule's name drawn over each other, both stretched.
        .fullScreenCover(item: $reviewing) { deck in
            ReviewView(deck: deck)
        }
        .sheet(item: $gate) { gate in
            AIGateSheet(gate: gate) {
                Task {
                    await Points.shared.refresh()
                    if let word = gatedOffer { keep(word) } else { send(draft.wrappedValue) }
                }
            }
        }
        // Following an answer down ends with it.
        .onChange(of: answering) { if !answering { following = false } }
        .onAppear {
            chats.open(key)
            let messages = chats.messages(in: key)
            // A conversation not yet begun, ready for the first question.
            if messages.isEmpty { focused = true }
            // Laid out just after the page began to come up, out of its animation, and opened at the end of what was
            // written: laid out in it, the conversation's height grew with the page over half a second, and a scroll to
            // its end found no end to go to; and a conversation shorter than the screen, sent to its end in it, with
            // nowhere to go, was left scrolling for good, taking no other scroll after.
            DispatchQueue.main.async {
                withTransaction(\.disablesAnimations, true) {
                    shown = true
                    if !messages.isEmpty { position.scrollTo(edge: .bottom) }
                }
            }
            #if DEBUG
            // `-askAI <question>`: asked as the conversation first opens, as if typed and sent (it costs what a
            // question costs).
            if let question = UserDefaults.standard.string(forKey: "askAI"), !Self.askedAtLaunch {
                Self.askedAtLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send(question) }
            }
            // `-reoffer YES`: what each answer offers asked again, with the prompt as it is now (`Chats.reoffer`).
            if UserDefaults.standard.bool(forKey: "reoffer") { chats.reoffer(in: key, saved: words.map(\.text)) }
            #endif
            // Opened again while an answer is being written: its question back at the top, the answer going on
            // under it, as it was left. The end first, then the question.
            if chats.answering.contains(key), let question = messages.last(where: { $0.role == .user })?.id {
                asked = question
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    position.scrollTo(id: question, anchor: .top)
                }
            }
        }
    }

    /// The conversation: what was said before the question last asked, then that question and what follows it, kept at
    /// least `room` tall.
    ///
    /// All of it laid out, not only what is in sight: a lazy stack guessed the height of what it hadn't made yet and
    /// corrected itself as messages came into sight, so the conversation jumped under the finger (55 pt in one frame on
    /// the phone), and its end, worked out from that guess, was 550 pt off when the keyboard came up far above it, the
    /// conversation stopping halfway there (user, 2026-10-09, a screen recording: "还是有不自然的地方"); a lazy stack
    /// for what was said long ago, under one laid out whole, drew messages over each other where the two met.
    ///
    /// Laid out at the width it has once on the screen, from the first frame: the page comes up widening from nothing
    /// to the screen's width (iOS 27), and laid out at each width, all its text was set again on every frame of it.
    private func transcript(_ messages: [Chat.Message], answering: Bool, split: Int, room: CGFloat,
                            wall: WallNow) -> some View {
        // A question sits close over its answer, and further from the answer before it, so the
        // conversation reads as questions with their answers rather than an even run of messages.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(messages[..<split]) { message in
                row(message, writing: false, vanishing: vanishing, wall: wall)
                    .padding(.top, Self.gap(above: message, first: messages.first?.id))
            }
            question(answering: answering, messages: messages, split: split, room: room, wall: wall)
        }
        // As wide as the scroll view offers, the column running past it while the page widens: content wider than the
        // scroll view took no scroll to its end.
        .frame(width: columnWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ScrollViewProbe { scrolled.found($0) } }
    }

    /// The conversation's width as it is once the page is on the screen: the window's, less its margins.
    private var columnWidth: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return (window?.bounds.width ?? UIScreen.main.bounds.width) - 2 * Self.side
    }

    /// Space between the conversation and the screen's sides.
    private static let side: CGFloat = 22

    /// The question last asked and what follows it, kept at least `room` tall; or, with none, why the last answer
    /// didn't come, if it didn't.
    @ViewBuilder
    private func question(answering: Bool, messages: [Chat.Message], split: Int, room: CGFloat,
                          wall: WallNow) -> some View {
        if split < messages.endIndex {
            VStack(alignment: .leading, spacing: Self.answerGap) {
                ForEach(messages[split...]) { message in
                    row(message, writing: answering && message.id == messages.last?.id,
                        vanishing: vanishing, wall: wall)
                }
                failure
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { latest = $0 }
            .frame(minHeight: room, alignment: .top)
            .padding(.top, split == 0 ? 0 : Self.questionGap)
            // The first question of a conversation rises from the field it was written in; later
            // ones rise with the conversation as it scrolls to them. (An offset transition did
            // nothing here, in a lazy stack in a scroll view; only its fade showed.)
            .offset(y: lifting ? room : 0)
            .opacity(lifting ? 0 : 1)
        } else {
            failure
                .padding(.top, Self.answerGap)
        }
    }

    /// Deletes the conversation, its words first going out of sight one after another, each message from its first
    /// character to its last, and the empty conversation coming up after (user, 2026-10-08: "在我们删除的时候，它是不是
    /// 可以做一些字符的那种消失的效果").
    ///
    /// Called by the system's question only once it has folded back into the trash, about a second after the tap
    /// (measured in the simulator: 1.2 s; Photos' own deletion waits as long, 1.3 s). A menu would call it at the tap,
    /// but looks unlike Photos' question; the question stays (user, 2026-10-08: "保持吧还是").
    private func vanish() {
        chats.stop(key)
        following = false
        vanishing = .now
        Task {
            try? await Task.sleep(for: .seconds(VanishRenderer.duration))
            chats.clear(key)
            asked = nil
            vanishing = nil
        }
    }

    /// The keyboard is coming: its room comes in at once, under the keyboard before it has moved, and the conversation
    /// goes to where its end will be with it, in the keyboard's own animation (scrolled by SwiftUI, it stood still while
    /// the keyboard's coming held the main thread, then jumped).
    private func keyboardWillShow(_ note: Notification) {
        let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let room = max(UIScreen.main.bounds.maxY - frame.minY - WallMetrics.homeIndicator, 0)
        let coming = !keyboardUp
        keyboardUp = true
        keyboardGoing = false
        if coming, let scrollView = scrolled.scrollView {
            let end = end(of: scrollView, withKeyboardRoom: room)
            if let carrier = scrolled.carrier, carrier.isCarrying {
                // A glide carried through the keyboard's hold (`carryGlide`) goes on until the hold lets go, and the
                // conversation goes to its end from where the glide has brought it then: sent off now, from where the
                // main thread last set it, it jumped back as the hold let go.
                DispatchQueue.main.async {
                    let drawn = scrollView.layer.presentation()?.bounds.origin.y ?? scrollView.contentOffset.y
                    carrier.drop()
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: drawn), animated: false)
                    scrollView.scroll(to: end, alongKeyboard: note)
                }
            } else {
                // A glide stops where the keyboard's coming caught it, rather than jumping on after it.
                scrollView.hold()
                scrollView.scroll(to: end, alongKeyboard: note)
            }
        }
        // The keyboard up changing its height (the emoji keys, say) is SwiftUI's to follow: at its end the conversation
        // keeps its end over the keyboard by itself (scrolled here as well, it went twice as far).
        setKeyboardRoom(room, inTurn: roomHolds)
    }

    /// Whether the room kept under the question last asked holds more than the question and its answer, so that it
    /// grows and shrinks with the keyboard's.
    private var roomHolds: Bool {
        scrolled.room.map { scrolled.latest < $0 } ?? false
    }

    /// Sets the keyboard's room under the conversation, and the room under the question last asked, which makes way for
    /// it. `inTurn`: the one that grows an update before the one that shrinks. In a single update SwiftUI took one
    /// before the other, and a conversation at its end was clamped to the end it had for that moment, for good (the
    /// question went down by the keyboard's height, its answer under the bar).
    private func setKeyboardRoom(_ room: CGFloat, inTurn: Bool) {
        guard inTurn, room != keyboardRoom else {
            keyboardRoom = room
            roomKeyboard = room
            return
        }
        if room > keyboardRoom {
            keyboardRoom = room
            DispatchQueue.main.async {
                if keyboardRoom == room { withTransaction(\.disablesAnimations, true) { roomKeyboard = room } }
            }
        } else {
            roomKeyboard = room
            DispatchQueue.main.async {
                if roomKeyboard == room { withTransaction(\.disablesAnimations, true) { keyboardRoom = room } }
            }
        }
    }

    /// The keyboard is going: the question just asked goes up to the top with it; otherwise its room goes as soon as it
    /// can (`giveUpKeyboardRoom`).
    private func keyboardWillHide(_ note: Notification) {
        keyboardUp = false
        keyboardGoing = true
        if risesWithKeyboard {
            risesWithKeyboard = false
            riseWithKeyboard(note)
        } else {
            giveUpKeyboardRoom(alongKeyboard: note)
        }
    }

    /// The question just asked goes up to the top as the keyboard goes, in the keyboard's own animation, the room under
    /// it growing into the keyboard's: the end, with the keyboard's room gone and that room grown by as much, is where the
    /// question is at the top.
    private func riseWithKeyboard(_ note: Notification) {
        if let scrollView = scrolled.scrollView {
            scrollView.hold()
            scrollView.scroll(to: end(of: scrollView, withKeyboardRoom: 0), alongKeyboard: note)
        }
        withTransaction(\.disablesAnimations, true) { setKeyboardRoom(0, inTurn: true) }
    }

    /// Where the conversation's end will be with the keyboard's room `room`: the room under the conversation moves it
    /// one way, and the room kept under the question last asked, which shrinks as much as the keyboard's grows, the
    /// other, as far as that room stands below the question's answer. Never above its top: a conversation shorter than
    /// the screen has its end there (sent above it, on the phone, it was thrown 300 pt down and back up).
    private func end(of scrollView: UIScrollView, withKeyboardRoom room: CGFloat) -> CGFloat {
        let change = Self.barBottom(keyboardRoom: room) - Self.barBottom(keyboardRoom: keyboardRoom)
        var end = scrollView.end + change
        if let kept = scrolled.room {
            end += max(scrolled.latest, kept - change) - max(scrolled.latest, kept)
        }
        return max(end, -scrollView.adjustedContentInset.top)
    }

    /// The keyboard is going: its room goes as soon as no finger is on the conversation and it isn't pulled past its
    /// top, as the wall's does (kept until the conversation stood still, the room showed as an empty space under its end
    /// when it was flung there). The end comes down into the room if it stood over it: with the keyboard, in its own
    /// animation, from a still conversation; otherwise on a curve of its own.
    private func giveUpKeyboardRoom(alongKeyboard note: Notification? = nil) {
        guard keyboardRoom != 0, !dragging, let scrollView = scrolled.scrollView,
              scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top - 1 else { return }
        // Whether the end comes down into the room: read off the scroll view as it is, as the wall's is.
        let end = end(of: scrollView, withKeyboardRoom: 0)
        let inTurn = roomHolds
        let giveUp = { setKeyboardRoom(0, inTurn: inTurn) }
        if scrollView.contentOffset.y <= end + 0.5 {
            // Without the animation the end of a glide hands the phase change in with.
            withTransaction(\.disablesAnimations, true, giveUp)
        } else if let note, !moving {
            scrollView.scroll(to: end, alongKeyboard: note)
            giveUp()
        } else {
            withAnimation(.smooth(duration: 0.35), giveUp)
        }
    }

    /// How far above the home indicator's room the bar's bottom stands, the keyboard's room counted: 8 pt above the keys,
    /// or with the keyboard away, below that room's top (the bar reaches into it, as the system's field does).
    private var barBottom: CGFloat { Self.barBottom(keyboardRoom: keyboardRoom) }

    /// The room under the conversation: the home indicator's, the bar's, and the keyboard's while it is up.
    private var bottomRoom: CGFloat { WallMetrics.homeIndicator + barBottom + barHeight }

    private static func barBottom(keyboardRoom room: CGFloat) -> CGFloat {
        room + WallMetrics.barPlacement(keyboard: room + WallMetrics.homeIndicator).bottom
    }

    /// Space between the conversation and the bars above and below it.
    private static let margin: CGFloat = 16

    /// Space between a question and its answer, and above a question.
    private static let answerGap: CGFloat = 20
    private static let questionGap: CGFloat = 36
    /// Space between an answer and the words it offers under it, and between two rows of what comes under it.
    private static let offerGap: CGFloat = 22
    private static let capsuleGap: CGFloat = 10

    /// The space above a message: an answer's, close under its question; a question's, further from the answer before
    /// it; none above the first.
    private static func gap(above message: Chat.Message, first: Chat.Message.ID?) -> CGFloat {
        if message.role == .assistant { return answerGap }
        return message.id == first ? 0 : questionGap
    }

    /// How a question rises to the top.
    private static let rise = Animation.smooth(duration: 0.5)

    /// The conversation's UIKit scroll view, and the room kept under the question last asked, if one is, with how tall the
    /// question and its answer are.
    private final class Scrolled {
        weak var scrollView: UIScrollView?
        var carrier: GlideCarrier?

        func found(_ scrollView: UIScrollView) {
            guard scrollView !== self.scrollView else { return }
            self.scrollView = scrollView
            carrier = GlideCarrier(scrollView)
        }

        var room: CGFloat?
        var latest: CGFloat = 0

        func note(room: CGFloat?, latest: CGFloat) {
            self.room = room
            self.latest = latest
        }
    }

    /// The wall as the conversation shows it: the words on it, or on their way to it, as compared (`EntryStyle.key`),
    /// for the words answers offer; its cards, for the decks they hand over, which count only those still on it; and
    /// the notes the word's page keeps, by id, for the notes answers offer.
    private struct WallNow {
        var keys: Set<String>
        var ids: Set<UUID>
        var noted: Set<UUID>
    }

    /// Where the conversation is scrolled to, as `onScrollGeometryChange` reports it.
    private struct Ends: Equatable {
        /// Scrolled to its end, give or take a few points.
        var atEnd: Bool
        /// More than a screen above its end.
        var far: Bool
    }

    @ViewBuilder
    private func row(_ message: Chat.Message, writing: Bool, vanishing: Date?, wall: WallNow) -> some View {
        if let vanishing {
            TimelineView(.animation) { context in
                vanishingRow(message, elapsed: context.date.timeIntervalSince(vanishing), wall: wall)
            }
        } else {
            row(message, writing: writing, wall: wall)
        }
    }

    @ViewBuilder
    private func row(_ message: Chat.Message, writing: Bool, wall: WallNow) -> some View {
        switch message.role {
        case .user:
            question(Text(message.text))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu { copy(message.text) }
        case .assistant:
            if message.text.isEmpty && message.deck == nil {
                // Until its first words come.
                ThinkingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A long press selects words in it once it is written (`SelectableText`), rather than opening a
                // menu of its own. The deck it hands over and the words it offers to keep come in under it once
                // they are known.
                VStack(alignment: .leading, spacing: 0) {
                    if !message.text.isEmpty {
                        StreamedText(text: message.text, writing: writing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let deck = message.deck, !writing {
                        let count = deck.words.filter(wall.ids.contains).count
                        if count > 0 {
                            Unfolding(since: chats.dealtAt[message.id]) {
                                DeckCapsule(title: deck.title, count: count) { reviewing = deck }
                                    .padding(.top, message.text.isEmpty ? 0 : Self.offerGap)
                            }
                        }
                    }
                    if let note = message.note, !writing, topicWord != nil {
                        Unfolding(since: chats.notedAt[message.id]) {
                            NoteCapsule(kept: wall.noted.contains(note.id)) { keepNote(note) }
                                .padding(.top, Self.offerGap)
                        }
                    }
                    if let offers = message.offers, !writing, keepOnWall != nil {
                        Unfolding(since: chats.offeredAt[message.id]) {
                            OfferCapsules(offers: offers, onWall: wall.keys, onKeep: keep)
                                .padding(.top, message.note == nil ? Self.offerGap : Self.capsuleGap)
                        }
                    }
                }
            }
        }
    }

    /// A question as it stands on the right, in its grey bubble; `fill`: how much of the bubble shows.
    private func question(_ text: some View, fill: Double = 1) -> some View {
        text
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(.fill.secondary.opacity(fill), in: .rect(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
    }

    /// A message going out of sight as the conversation is deleted, `elapsed` seconds in (`VanishRenderer`): a
    /// question's bubble fading as its words go, an answer set as it was, so nothing moves.
    @ViewBuilder
    private func vanishingRow(_ message: Chat.Message, elapsed: TimeInterval, wall: WallNow) -> some View {
        let renderer = VanishRenderer(elapsed: elapsed)
        switch message.role {
        case .user:
            question(Text(message.text).textRenderer(renderer),
                     fill: 1 - Easing.smooth((elapsed - VanishRenderer.spread / 2) / VanishRenderer.fade))
        case .assistant:
            if message.text.isEmpty && message.deck == nil {
                ThinkingText()
                    .opacity(1 - Easing.smooth(elapsed / VanishRenderer.fade))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // What came under it goes with its last characters.
                let after = 1 - Easing.smooth((elapsed - VanishRenderer.spread) / VanishRenderer.fade)
                VStack(alignment: .leading, spacing: 0) {
                    if !message.text.isEmpty {
                        MixedText(message.text)
                            .lineHeight(.exact(points: lineHeight))
                            .textRenderer(renderer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let deck = message.deck {
                        let count = deck.words.filter(wall.ids.contains).count
                        if count > 0 {
                            DeckCapsule(title: deck.title, count: count) {}
                                .padding(.top, message.text.isEmpty ? 0 : Self.offerGap)
                                .opacity(after)
                        }
                    }
                    if let note = message.note, topicWord != nil {
                        NoteCapsule(kept: wall.noted.contains(note.id)) {}
                            .padding(.top, Self.offerGap)
                            .opacity(after)
                    }
                    if let offers = message.offers, keepOnWall != nil {
                        OfferCapsules(offers: offers, onWall: wall.keys, onKeep: { _ in })
                            .padding(.top, message.note == nil ? Self.offerGap : Self.capsuleGap)
                            .opacity(after)
                    }
                }
            }
        }
    }

    /// Why the last answer didn't come, if it didn't.
    @ViewBuilder
    private var failure: some View {
        if let failure = chats.failures[key] {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
    }

    /// Asks the question and lifts it to the top, the conversation rising under the bars from the field it was
    /// written in. The keyboard goes, so the answer has the screen, as in ChatGPT (user, 2026-10-09: "要不还是问完落键盘
    /// 得了？可能会好点？"). It stayed up for a day (user, 2026-10-08: "怎么每次键盘都落下去"): the answer was then written
    /// over the keyboard in a third of the screen, and the keyboard put down in the middle of it left its room standing
    /// empty under it.
    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chats.answering.contains(key) else { return }
        // The question waits in the field while the user agrees to AI, tops up their points or enters a key.
        if let stop = AIGate.check(needing: Points.question) {
            focused = false
            gatedOffer = nil
            gate = stop
            return
        }
        draft.wrappedValue = ""
        following = false
        // Asked from far up the conversation: to its end at once, and the question rises from there, rather than the
        // whole conversation flying past.
        if farFromEnd {
            position.scrollTo(edge: .bottom)
            DispatchQueue.main.async { ask(question) }
        } else {
            ask(question)
        }
    }

    /// Puts a word an answer offers on the wall, as if it had been typed into the wall's field; a word the wall hasn't
    /// got needs AI, and waits while the user agrees to AI, tops up their points or enters a key.
    private func keep(_ word: String) {
        guard let keepOnWall else { return }
        if !wallKeys.contains(EntryStyle.key(word)), let stop = AIGate.check(needing: Points.newWord) {
            focused = false
            gatedOffer = word
            gate = stop
            return
        }
        gatedOffer = nil
        keeping.insert(EntryStyle.key(word))
        keepOnWall(word)
    }

    /// Keeps what an answer offers on the word's page, under You Asked.
    private func keepNote(_ note: WordNote) {
        guard let topicWord, !topicWord.notes.contains(where: { $0.id == note.id }) else { return }
        topicWord.notes.append(note)
        try? modelContext.save()
    }

    /// The wall's words and what was typed for them, as compared (`EntryStyle.key`).
    private var wallKeys: Set<String> {
        Set(words.flatMap { [$0.text, $0.request].compactMap { $0 }.map(EntryStyle.key) })
    }

    #if DEBUG
    /// Whether `-askAI` has asked its question in this launch.
    private static var askedAtLaunch = false
    #endif

    private func ask(_ question: String) {
        let first = chats.messages(in: key).isEmpty
        lifting = first
        asked = chats.send(question, in: key, context: context, saved: words.map { (text: $0.text, id: $0.id) },
                           about: topicWord?.text)
        // The question goes up with the keyboard as it goes (`riseWithKeyboard`); without one on the screen, by itself.
        risesWithKeyboard = keyboardUp && !first
        focused = false
        if risesWithKeyboard { return }
        if first {
            // Down at the field for a frame, then up to its place.
            DispatchQueue.main.async { withAnimation(Self.rise) { lifting = false } }
        } else if let asked {
            // Up to the top, by its id: the room under it being the screen between the bars, that is the end, and the
            // conversation is then held with the question there however the keyboard's height changes (a row of
            // Chinese candidates, the emoji keys), until a finger moves it. Sent to "the end", it was held at the end,
            // which the room's making way for the keyboard moves a moment apart from the keyboard's room.
            // An update after the question and its room are in: sent in the same one, the room came in in the rise's
            // animation, and in a conversation shorter than the screen the rise found nowhere to go.
            DispatchQueue.main.async { withAnimation(Self.rise) { position.scrollTo(id: asked, anchor: .top) } }
        }
    }
}

/// What comes in under an answer once it is written, growing from nothing to its height and fading in, `since` it came:
/// the room it takes grows on every frame, laid out each time, so a conversation kept at its end goes up with it, as with
/// an answer being written. Brought in in an animation, it left such a conversation where it was, with the words under the
/// bar (SwiftUI put off the scroll view's new size, and an animated scroll to the end was undone), and without one the
/// conversation jumped up by their height in a frame. Already there when the conversation is opened, it is just there.
private struct Unfolding<Content: View>: View {
    var since: Date?
    var content: Content
    /// How tall it is, grown.
    @State private var height: CGFloat = 0
    @State private var grown: Bool
    @State private var shown: Bool

    init(since: Date?, @ViewBuilder content: () -> Content) {
        self.since = since
        self.content = content()
        let done = since.map { Date.now.timeIntervalSince($0) >= Self.growing } ?? true
        _grown = State(initialValue: done)
        _shown = State(initialValue: done)
    }

    var body: some View {
        // Read here rather than only in the timeline's closure, which then never saw it change.
        let height = height
        // The room it takes: a copy of it out of sight, which never changes its size. What is seen lies over it, outside
        // the timeline: drawn in it, once the timeline had stopped it was left as it was, and the words tapped never
        // took their ticks.
        TimelineView(.animation(paused: grown)) { context in
            let t = since.map { context.date.timeIntervalSince($0) } ?? .infinity
            content
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.height = $0 }
                .frame(height: t >= Self.growing ? nil : height * Easing.spring(t, duration: Self.duration),
                       alignment: .top)
        }
        .overlay(alignment: .top) {
            content.opacity(shown ? 1 : 0)
        }
        .onAppear {
            if !shown { withAnimation(.smooth(duration: Self.duration)) { shown = true } }
        }
        .task(id: since) {
            guard let since, !grown else { return }
            try? await Task.sleep(for: .seconds(max(0, Self.growing - Date.now.timeIntervalSince(since)) + 0.05))
            grown = true
        }
    }

    private static var duration: Double { 0.5 }
    /// How long it takes to grow: the spring is within half a percent of its height by then.
    private static var growing: Double { duration * 1.3 }
}

/// What a word's conversation can keep on its page from an answer and its question (`WordNote`), under the answer: one
/// glass capsule, as the words answers offer are; tapped, the note goes under You Asked on the word's page, and the
/// capsule says so, as it does while the note is there (user, 2026-10-18).
private struct NoteCapsule: View {
    var kept: Bool
    var onKeep: () -> Void

    var body: some View {
        Button {
            if !kept { onKeep() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kept ? "checkmark" : "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
                Text(kept ? "Added to Card" : "Add to Card")
                    .font(.body.weight(.semibold))
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(kept ? .regular : .regular.interactive(), in: .capsule)
        .animation(.smooth(duration: 0.35), value: kept)
    }
}

/// A deck an answer handed over (`Chat.Deck`), under it: one glass capsule, as the words answers offer are, with the
/// deck's name and how many of its cards are on the wall; tapped, it opens review of those cards alone (user,
/// 2026-10-18: after eight ways of showing its cards beside the answer, the last two "丑", chose "一颗胶囊"). The stacked
/// cards are review's symbol, as on the wall's Review button.
private struct DeckCapsule: View {
    let title: String
    let count: Int
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.body.weight(.semibold))
                Text(count, format: .number)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("\(title), \(count) cards")
        .accessibilityHint("Reviews these cards.")
    }
}

/// The words an answer offers to keep on the wall, under it once it is written: a glass capsule each, with its word in
/// the answer's serif and its meaning, side by side, or one under the other when they don't fit (user, 2026-10-18, of
/// four ways tried: "胶囊似乎可以的哦"). Tapped, the word goes on the wall as if typed there, and its capsule turns into
/// a tick and the word, as it stays while the word is on the wall.
private struct OfferCapsules: View {
    let offers: [Chat.Offer]
    /// The words on the wall, or on their way to it, as compared (`EntryStyle.key`).
    let onWall: Set<String>
    var onKeep: (String) -> Void

    var body: some View {
        // Always in one row (user, 2026-10-18, of two that didn't fit and went one under the other: "这个胶囊怎么是两行啊，
        // 有点奇怪吧"): with their meanings if they fit so, else the words alone, else the first alone, cut short only if
        // even it doesn't fit (two long phrases were both cut short). Chosen by how wide they are as offered, so a capsule
        // turning into a tick, and shorter, leaves them as they were (chosen again, they were made again and came back in
        // a blur).
        let first = Array(offers.prefix(1))
        ViewThatFits(in: .horizontal) {
            fitted(offers, meanings: true)
            fitted(offers, meanings: false)
            fitted(first, meanings: true)
            capsules(first, meanings: false)
        }
        .animation(.smooth(duration: 0.35), value: onWall)
    }

    private static let spacing: CGFloat = 8

    /// The capsules, over the room they take as offered.
    private func fitted(_ offers: [Chat.Offer], meanings: Bool) -> some View {
        HStack(spacing: Self.spacing) { ForEach(offers) { label($0, kept: false, meaning: meanings) } }
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .leading) { capsules(offers, meanings: meanings) }
    }

    private func capsules(_ offers: [Chat.Offer], meanings: Bool) -> some View {
        // Together for their glass, but never run into one another.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Self.spacing) {
                ForEach(offers) { offer in
                    let kept = onWall.contains(EntryStyle.key(offer.word))
                    Button {
                        if !kept { onKeep(offer.word) }
                    } label: {
                        label(offer, kept: kept, meaning: meanings)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(kept ? .regular : .regular.interactive(), in: .capsule)
                    .accessibilityLabel(kept ? "\(offer.word), on the wall" : "Add \(offer.word), \(offer.meaning)")
                }
            }
        }
    }

    /// A plus, the word in the answer's serif and, with `meaning`, its meaning; once kept, a tick and the word.
    private func label(_ offer: Chat.Offer, kept: Bool, meaning: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kept ? "checkmark" : "plus")
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                // As wide either way: the tick, wider than the plus, cut short a word laid out for the plus.
                .frame(width: 16)
            Text(offer.word)
                .font(.system(.body, design: .serif).weight(.semibold))
            if meaning && !kept {
                Text(OfferClient.shortMeaning(offer.meaning))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .layoutPriority(-1)
                    // Gone before the capsule's end comes past it: the glass cuts off what it goes over.
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

/// The question being written, in one glass field the width of the screen; once there is something to send, a black send
/// button sits inside it at its end, as Siri's does, and the same button stops an answer being written (user,
/// 2026-10-07: "发送键是放在这个…输入框当中的…这个发送按钮的形状也值得我们学习"). No voice button for now ("这个语音现在哪儿
/// 都没做呢。把语音先去掉吧"). Nothing suggests what to ask ("不要有这些…提示…大家该怎么问就怎么问").
///
/// It rides the keyboard (`KeyboardRidingBar`), in its own hosting: its focus and its shape are its own, kept in step with
/// the conversation's through `focused`, and its height goes out to the conversation's room through `height`. Over the
/// keyboard it widens to 8 pt from the screen's sides, as the system's field does, and takes its resting shape again as
/// the keyboard sets off down, at a drag's letting go too, rather than once the keyboard has gone (user, 2026-10-07: "这个
/// 键盘落下的时候，怎么才能舒服": the bar came down in its keyboard shape and only then narrowed).
private struct ChatBar: View {
    @Binding var text: String
    var answering: Bool
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var onSend: () -> Void
    var onStop: () -> Void
    @FocusState private var fieldFocused: Bool
    /// Whether the keyboard is up, inside an animation of its own.
    @State private var raised = false

    var body: some View {
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inField = ready || answering
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask anything", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($fieldFocused)
                    .padding(.vertical, 13)
                // Room for the send button, which lies over the glass rather than in it: anything in the glass, or
                // anywhere in its container, the glass drew in its own vibrant grey.
                if inField { Color.clear.frame(width: 38, height: 28).padding(.vertical, 10) }
            }
            .padding(.leading, 20)
            .padding(.trailing, inField ? 10 : 20)
            .frame(minHeight: WallMetrics.barHeight)
            .contentShape(.rect(cornerRadius: WallMetrics.barHeight / 2, style: .continuous))
            .onTapGesture { fieldFocused = true }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: WallMetrics.barHeight / 2, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .overlay(alignment: .bottomTrailing) {
            if inField {
                sendButton
                    .padding([.trailing, .bottom], 10 - Self.reach)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, raised ? WallMetrics.barInsetOverKeyboard : WallMetrics.barInset)
        .animation(.smooth(duration: 0.3), value: inField)
        .onChange(of: fieldFocused) { _, now in if focused != now { focused = now } }
        .onChange(of: focused, initial: true) { _, now in if fieldFocused != now { fieldFocused = now } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.smooth) { raised = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.smooth) { raised = false }
        }
    }

    /// How far beyond the send button's pill a touch still presses it.
    private static let reach: CGFloat = 8

    /// Black, a short pill, inside the field at its end, with a heavy arrow: Siri's ("这个发送按钮的形状也值得我们学习").
    /// Black without glass over it, which turned it grey, and the same shape however it is pressed.
    private var sendButton: some View {
        Button {
            if answering { onStop() } else { onSend() }
        } label: {
            Image(systemName: answering ? "stop.fill" : "arrow.up")
                .font(.system(size: answering ? 12 : 15, weight: .bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 38, height: 28)
                .background(Color.primary, in: .capsule)
                // A finger's width all round, 54 × 44, though the pill is small.
                .padding(Self.reach)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(answering ? "Stop" : "Send")
    }
}
