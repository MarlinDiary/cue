import SwiftUI

/// Siri's cards are one template scaled to the column: type, padding and corner radius all grow with the card's
/// width, while the gaps between cards stay fixed. Everything here is measured from the iOS 27 Siri app at a
/// 179 pt card.
enum CardMetrics {
    static let baseWidth: CGFloat = 179
    /// Width over height. Siri's cards are a touch squatter than 4:3: 179 by 238 pt on a 402 pt phone, and 562 by
    /// 748 px (at 3x) on a 420 pt phone.
    static let aspect: CGFloat = 562 / 748
    static let radiusRatio: CGFloat = 39 / 179
}

/// Continuous corners (Apple's squircle, as Siri's cards measure) whose radius follows the card's width. Insetting
/// keeps the corners concentric.
struct CardShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = rect.width * CardMetrics.radiusRatio - insetAmount
        return RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> CardShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// One word on the wall: a 3:4 Liquid Glass card. Everything inside it is plain content, never more glass.
struct WordCard: View {
    let word: Word
    /// The title's frame while a new word is written, for the user's own words to rise into when the headword turns out
    /// to be them.
    @State private var titleFrame: CGRect = .zero
    /// Whether the title needs more than two lines at full size: a long sentence, which the card shows in English alone,
    /// on as many as four lines at full size rather than shrunk into two (user, 2026-10-06: "只显示英文似乎也可以",
    /// "句子为啥不多写几行").
    @State private var titleIsLong = false

    var body: some View {
        Color.clear
            .aspectRatio(CardMetrics.aspect, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    content(scale: proxy.size.width / CardMetrics.baseWidth, size: proxy.size)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            // Plain glass: interactive glass lights up a glow under the finger, which reads as an odd oval mask
            // on a card this large. `CardPressStyle` gives the press feedback instead.
            .glassEffect(.regular, in: CardShape())
            .contentShape(CardShape())
    }

    private func content(scale s: CGFloat, size: CGSize) -> some View {
        // A new word's card is written in front of the user: the user's own words wait in the middle, then the
        // headword, the meaning and the picture's description come in word by word as AI sends them, one after another.
        let generation = Lexicographer.shared.generation(for: word)
        let schedule = generation?.cardSchedule
        let title = generation.map { $0.headword ?? " " } ?? word.text
        let summary = generation.map(\.summary) ?? word.entry?.summary
        let showsPicture = WordPicture.isShown(for: word)
        let titleFont = Font.system(size: 24 * s, weight: .bold)
        let inner = CGSize(width: size.width - 40 * s, height: size.height - 40 * s)
        // The user's own words hold the card until the headword is in; when they are the headword, they stand in for
        // the title until then.
        let holding = generation.map { $0.headword == nil || !$0.cardSchedule.isDone(0, at: .now) } ?? false
        let standingIn = holding && generation?.same == true
        // A long sentence takes up to four lines; a phrase two; a single word one, shrinking to fit.
        // Only a sentence too long for two lines is set on up to four, in English alone. A long phrase ("fish with
        // pickled mustard greens") keeps two lines, shrinking to fit, and its Chinese (user, 2026-10-07: it took four).
        let longSentence = titleIsLong && EntryStyle.isSentence(title, summary: summary)
        let titleLines = longSentence ? 4 : generation != nil || title.contains(" ") ? 2 : 1
        // No date: when a word was saved says little about it. The word leads, as on its page.
        return VStack(alignment: .leading, spacing: 0) {
            // The title takes the lines it needs, at the top. A two-line box with the title on its bottom line, kept so
            // nothing moved when the user's words in the title's place gave way to a longer headword, left a single
            // word sitting low under an empty line ("dog"); with the user's words waiting in the middle instead,
            // nothing is shown below the title yet when its length becomes known.
            Group {
                if let schedule, let generation, !generation.same {
                    TypedLine(text: title, schedule: schedule, index: 0)
                } else {
                    Text(title)
                }
            }
            .font(titleFont)
            .lineLimit(titleLines)
            .minimumScaleFactor(0.6)
            .opacity(standingIn ? 0 : 1)
            .transaction(value: standingIn) { $0.animation = nil }
            .background {
                if generation != nil {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("card")) } action: { titleFrame = $0 }
                }
            }

            if summary != nil || schedule != nil, !longSentence {
                Group {
                    if let schedule {
                        TypedLine(text: summary ?? " ", schedule: schedule, index: 1)
                    } else if let summary {
                        Text(summary)
                    }
                }
                .font(.system(size: 16 * s))
                .foregroundStyle(.secondary)
                .lineLimit(showsPicture ? 2 : 6)
                .padding(.top, 6 * s)
            }

            if showsPicture {
                // Centred in the space left, where the page's picture lands when the card zooms open: the page sets it
                // under the word at the same size as here, once the page is scaled to the card's width.
                GeometryReader { proxy in
                    WordPicture(word: word, area: 10_700 * s * s, maxWidth: proxy.size.width,
                                maxHeight: proxy.size.height, schedule: schedule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 10 * s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // The title at full size with no line limit, to tell a long sentence from one that fits its two lines.
            let line = UIFont.systemFont(ofSize: 24 * s, weight: .bold).lineHeight
            Text(title)
                .font(titleFont)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > 2.5 * line } action: { titleIsLong = $0 }
        }
        .coordinateSpace(.named("card"))
        .overlay(alignment: .topLeading) {
            // The user's own words, in the middle of the card until the headword comes.
            if let generation, let schedule, holding {
                GenerationPlaceholder(text: generation.placeholder, headword: generation.same ? generation.headword : nil,
                                      font: titleFont, fontSize: 24 * s,
                                      center: CGPoint(x: inner.width / 2, y: inner.height / 2), width: inner.width,
                                      slot: titleFrame, schedule: schedule, lines: titleLines)
                    .transition(.identity)
            }
        }
        .padding(20 * s)
    }
}

/// Cards sink a little under the finger and keep their exact shape, like App Store cards. `onPress`: told as the
/// card is pressed and let go of.
struct CardPressStyle: ButtonStyle {
    var onPress: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// The card a finger is on, while the wall isn't picking cards: one card at a time takes a touch then, as one opens at
/// a time (user, 2026-10-09: "在非这样的情况之下，我们正常的点击打开页面的这个详情的时候，我们现在居然允许的是两张卡片同时点击";
/// two fingers on two cards opened both, one page over the other).
@Observable
final class CardPress {
    private(set) var card: UUID?

    func press(_ id: UUID, _ pressed: Bool) {
        if pressed {
            if card == nil { card = id }
        } else if card == id {
            card = nil
        }
    }

    /// Lets go of a card gone from the wall with a finger on it, which says nothing as it goes.
    func gone(_ id: UUID) {
        if card == id { card = nil }
    }
}

/// Takes no touch while a finger is on another card (`CardPress`), unless the wall is picking cards (`picking`), when
/// fingers pick several at once.
struct CardPressLock: ViewModifier {
    let press: CardPress
    let id: UUID
    let picking: Bool

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(picking || press.card == nil || press.card == id)
            .onDisappear { press.gone(id) }
    }
}
