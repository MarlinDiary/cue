import CoreText
import SwiftUI

/// The picture's description, set where the picture will be, its words coming into focus one after another the way
/// the system's writing tools bring text in (chosen on 2026-10-06 over a typewriter with a cursor, which had been
/// shipped first).
struct TypedIdea: View {
    var text: String
    /// Seconds since the words began to come in.
    var shown: TimeInterval
    var fontSize: CGFloat
    /// The width the text is set in, centred in the picture's room.
    var width: CGFloat
    /// Seconds since the picture arrived (negative until then), when the letters fly into its subject and take its
    /// colours, given its trace and where the picture sits in the text's own coordinates.
    var gone: TimeInterval = -1
    var trace: Silhouette.Trace?
    var pictureRect: CGRect = .zero
    /// Whether the picture is still being drawn: once the words have settled they float on a slow swell, which dies
    /// down as it arrives.
    var waiting = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(Font(Self.font(size: fontSize)))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineSpacing(fontSize * 0.16)
            // A long description shrinks to fit its room rather than being cut short.
            .minimumScaleFactor(0.7)
            .frame(width: width)
            // At the pace of the rest of the card (it was halved for a while to fill the picture's wait; the swell does
            // that now).
            .textRenderer(WordsRenderer(shown: shown, words: WordsRenderer.words(of: text), gone: gone,
                                        trace: trace, pictureRect: pictureRect,
                                        ink: colorScheme == .dark ? SIMD3(repeating: 1) : .zero, baseOpacity: 0.55,
                                        waiting: waiting))
    }
}

extension TypedIdea {
    /// New York italic at `size`, its optical size held at a card's 12.5 pt, so the page, setting the words larger,
    /// breaks them into exactly the card's lines: left to itself, the larger size takes letterforms 6% narrower and
    /// fits more on a line.
    static func font(size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size).fontDescriptor
        let serif = system.withDesign(.serif) ?? system
        let descriptor = (serif.withSymbolicTraits(.traitItalic) ?? serif)
            .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontOpticalSizeAttribute as String): 12.5])
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// A line of a card or page whose words come into focus as it arrives: the headword, the meaning, the pronunciation.
/// Its font and colour are the caller's.
struct TypedLine: View {
    var text: String
    /// The timing of the pieces' arrival, and this line's place in it.
    var schedule: TypingSchedule
    var index: Int

    var body: some View {
        let lead = schedule.lead(index)
        TimelineView(.animation(minimumInterval: 1 / 60, paused: schedule.isDone(index, at: .now))) { context in
            let shown = schedule.shown(index, at: context.date) - lead
            Text(text).textRenderer(WordsRenderer(shown: shown, words: WordsRenderer.words(of: text), baseOpacity: 1))
        }
    }
}

/// The user's own words, set in the middle of a new card or page while AI decides the headword: nothing else is
/// known yet, and it shows at once which card this is. When the headword comes they give way softly while it comes in
/// at the top; when the headword is the very words the user typed, they rise into its place instead and stand in for
/// it until the card or page takes over. It takes over in the update that removes these words, so the title is never
/// missing or doubled for a frame, as it was when each kept its own clock (2026-10-06).
struct GenerationPlaceholder: View {
    var text: String
    /// The headword, when it is the user's own words (perhaps cased differently): what they rise into.
    var headword: String?
    var font: Font
    var fontSize: CGFloat
    /// Where they wait (their centre), and the width they are set in, which is the title's.
    var center: CGPoint
    var width: CGFloat
    /// The title's frame, for the rise.
    var slot: CGRect
    /// The headword's coming in is piece 0 of the schedule.
    var schedule: TypingSchedule
    /// The title's line limit, so the rising words are set exactly as it is.
    var lines = 2

    /// How long the rise takes; the headword is in place when it ends.
    static let rise = 0.6
    /// How long the words take to give way otherwise, and how soon the headword starts coming in meanwhile.
    static let fade = 0.45
    static let overlap = 0.2

    var body: some View {
        let waiting = schedule.shown(0, at: .now) < 0
        TimelineView(.animation(minimumInterval: 1 / 60, paused: waiting)) { context in
            let t = schedule.shown(0, at: context.date)
            ZStack(alignment: .topLeading) {
                if let headword, slot != .zero {
                    // Up into the title on the wall's own spring, lines drawing in from centred to flush left, and
                    // darkening as they go: the grey words become the black headword, there when they land.
                    let m = t < Self.rise ? Easing.spring(t) : 1
                    let dark = Easing.smooth((m - 0.15) / 0.75)
                    ZStack {
                        words(text, lines: lines, lean: m).foregroundStyle(.secondary).opacity(1 - dark)
                        words(headword, lines: lines, lean: m).foregroundStyle(.primary).opacity(dark)
                    }
                    .position(x: center.x + (slot.midX - center.x) * m, y: center.y + (slot.midY - center.y) * m)
                } else if t < Self.fade {
                    // Giving way: a soft blur, a touch smaller, gone, as the headword comes in above.
                    let p = Easing.smooth(t / Self.fade)
                    words(text, lines: 4, lean: 0)
                        .foregroundStyle(.secondary)
                        .blur(radius: fontSize / 5 * p)
                        .scaleEffect(1 - 0.04 * p)
                        .opacity(1 - p)
                        .position(center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Set as the title is (its line limit, shrinking to fit) once they are to become it; up to four lines while they
    /// wait.
    private func words(_ text: String, lines: Int, lean: Double) -> some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .minimumScaleFactor(0.6)
            .textRenderer(LeaningLines(lean: lean))
            .frame(width: width)
    }
}

/// Draws centred text with its lines moved towards the leading edge, flush left at 1: for words that wait centred and
/// rise into a title set flush left, whose lines would otherwise jump sideways when it takes over.
nonisolated struct LeaningLines: TextRenderer {
    var lean: Double

    /// So the lines lean over as an animation runs, as review's question rises into its card's title.
    var animatableData: Double {
        get { lean }
        set { lean = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let left = layout.map(\.typographicBounds.rect.minX).min() ?? 0
        for line in layout {
            var copy = context
            copy.translateBy(x: (left - line.typographicBounds.rect.minX) * lean, y: 0)
            copy.draw(line)
        }
    }
}

/// When the pieces of a new word come in: each starts when it has arrived and the piece before it is in, so they
/// come in order and never two at once.
nonisolated struct TypingSchedule: Equatable {
    struct Field: Equatable {
        /// Nil until the piece has arrived.
        var text: String?
        var arrival: Date?
        /// Time taken before the words come in, for whatever held the place to go (or rise into it).
        var lead: TimeInterval = 0
        /// Whether the words appear all at once when the lead is over.
        var instant = false
    }

    private var starts: [Date?] = []
    private var ends: [Date?] = []
    private var leads: [TimeInterval] = []
    /// How many times faster than usual the pieces come in: a card coming in again goes through it quickly.
    private var speed: Double = 1

    init(_ fields: [Field], speed: Double = 1) {
        self.speed = speed
        // Nil once a piece hasn't come: everything after it waits.
        var previousEnd: Date? = .distantPast
        for field in fields {
            leads.append(field.lead)
            guard let before = previousEnd, let text = field.text, let arrival = field.arrival else {
                starts.append(nil)
                ends.append(nil)
                previousEnd = nil
                continue
            }
            let start = max(arrival, before)
            let end = start.addingTimeInterval((field.lead + (field.instant ? 0 : WordsRenderer.duration(of: text))) / speed)
            starts.append(start)
            ends.append(end)
            previousEnd = end
        }
    }

    /// Seconds since the piece began (its lead included), at its speed; negative before.
    func shown(_ index: Int, at now: Date) -> TimeInterval {
        index < starts.count ? starts[index].map { now.timeIntervalSince($0) * speed } ?? -1 : -1
    }

    func lead(_ index: Int) -> TimeInterval { index < leads.count ? leads[index] : 0 }

    /// When the piece will be fully in, once it has arrived.
    func end(_ index: Int) -> Date? { index < ends.count ? ends[index] : nil }

    /// Whether the piece is fully in.
    func isDone(_ index: Int, at now: Date) -> Bool {
        index < ends.count && ends[index].map { $0 <= now } == true
    }
}

/// Draws text word by word as it comes in, each word coming into focus from a soft blur and settling down a touch,
/// the way the system's writing tools bring text in. Chinese, which has no spaces, comes in by the character.
nonisolated struct WordsRenderer: TextRenderer {
    var shown: TimeInterval
    /// Which word each character belongs to, in order.
    var words: [Int]
    /// Seconds between one word's coming in and the next's.
    var stagger = WordsRenderer.stagger
    var gone: TimeInterval = -1
    var trace: Silhouette.Trace?
    var pictureRect: CGRect = .zero
    /// The text's own colour (black or white), which the picture's colours mix from.
    var ink: SIMD3<Float> = .zero
    /// Whether the words come in all together, without the blur and lift: for words that were already there.
    var plain = false
    /// How dark the letters sit: the description is set lighter than a headword.
    var baseOpacity = 1.0
    /// Whether the words are waiting for their picture: once settled, they float on a slow swell until it comes.
    var waiting = false
    /// How long the words rest, once in, before the swell begins.
    var settle = 1.0

    /// One word after another, each taking this long to come into focus.
    static let stagger = 0.09
    static let fade = 0.35

    /// Seconds into the wait, from a second after the last word is in, and how strongly it shows: fully until the
    /// picture arrives, then fading over 0.3 s as the letters set off to gather into it. Nil while the words come in.
    private var wait: (time: Double, amount: Double)? {
        guard waiting else { return nil }
        let time = shown - (Double(words.last ?? 0) * stagger + Self.fade) - settle
        let amount = gone > 0 ? 1 - Easing.smooth(gone / 0.3) : 1
        return time > 0 && amount > 0 ? (time, amount) : nil
    }

    /// The swell the waiting words float on, so the wait is seen to go on (picked by the user on 2026-10-06 from
    /// nine: a light sweeping over the words, too strong and then too faint to see; a sheen; a glow read through them;
    /// breathing; a ripple through the words and five variations on it): crests about two thirds of the text apart
    /// run left to right every 2.6 s, without pause, lifting a letter by up to 7% of its height and darkening it a
    /// shade; eased in over the first second. How far a letter sits above its line and how much darker, `time` seconds
    /// into the wait.
    private func swell(at time: Double, glyph: CGRect, block: CGRect) -> (lift: Double, darkness: Double) {
        guard block.width > 0 else { return (0, 0) }
        let s = sin(2 * Double.pi * ((glyph.midX - block.minX) / (0.7 * block.width) - time / 2.6))
        let ramp = Easing.smooth(time / 1.2)
        return (glyph.height * 0.07 * s * ramp, 0.06 * (1 + s) / 2 * ramp)
    }

    /// A small fixed offset per letter, so they don't all move at once.
    private static func jitter(_ index: Int) -> Double { Double((index &* 2_654_435_761) & 0xFFFF) / 65_535 }

    /// The word each character of `text` belongs to: a run of letters between spaces, or a single Chinese character.
    static func words(of text: String) -> [Int] {
        var words: [Int] = []
        var word = -1
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
                words.append(max(word, 0))
            } else if character.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                word += 1
                inWord = false
                words.append(word)
            } else {
                if !inWord { word += 1; inWord = true }
                words.append(word)
            }
        }
        return words
    }

    /// How long the text takes to come in: the last word's start, plus its fade.
    static func duration(of text: String, stagger: TimeInterval = WordsRenderer.stagger) -> TimeInterval {
        text.isEmpty ? 0 : Double(words(of: text).last ?? 0) * stagger + fade
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The gathering: when the picture arrives, each letter flies to a point of the picture's subject, taking the
        // picture's colour there as it goes, and dissolves on landing; the picture is revealed where the letters land
        // (`WordPicture` masks it the same way), so it seems to form out of them.
        let interior = trace?.interior ?? []
        let targets = interior.map { CGPoint(x: pictureRect.minX + $0.x * pictureRect.width,
                                             y: pictureRect.minY + $0.y * pictureRect.height) }
        let gathering = gone > 0 && !targets.isEmpty
        let total = max(layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }, 1)
        let wait = self.wait
        let block = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let rect = slice.typographicBounds.rect
                    let i = index
                    let word = plain ? 0 : i < words.count ? words[i] : i
                    index += 1
                    // The word comes into focus: from a soft blur, a touch above its place, over a third of a second.
                    let p = min(max((shown - Double(word) * stagger) / Self.fade, 0), 1)
                    guard p > 0 else { continue }
                    let eased = 1 - (1 - p) * (1 - p)
                    var copy = context
                    var darkness = baseOpacity
                    if let wait {
                        let afloat = swell(at: wait.time, glyph: rect, block: block)
                        darkness += afloat.darkness * wait.amount
                        copy.translateBy(x: 0, y: -afloat.lift * wait.amount)
                    }
                    copy.opacity = eased * darkness
                    if p < 1, !plain {
                        copy.addFilter(.blur(radius: rect.height / 4 * (1 - eased)))
                        copy.translateBy(x: 0, y: -rect.height * 0.12 * (1 - eased))
                    }
                    var zoom = 1.0
                    var tint: SIMD3<Float>?
                    if gathering {
                        let fraction = Double(i) / Double(max(total - 1, 1))
                        let j = min((i * targets.count) / total, targets.count - 1)
                        let jitter = Self.jitter(i)
                        let flown = Gather.arrival(gone, fraction: fraction, jitter: jitter)
                        copy.translateBy(x: (targets[j].x - rect.midX) * flown, y: (targets[j].y - rect.midY) * flown)
                        zoom *= 1 - 0.4 * flown
                        if let under = trace?.colors.color(at: interior[j]) {
                            let k = Float(min(1, flown * 1.25))
                            tint = ink + (under - ink) * k
                            copy.opacity = p * (darkness + (1 - darkness) * Double(k))
                        }
                        // Landed: the letter dissolves into the picture forming under it.
                        let dissolve = Easing.smooth((Gather.elapsed(gone, fraction: fraction, jitter: jitter) - Gather.flight) / 0.25)
                        copy.opacity *= 1 - dissolve
                        if dissolve > 0 { copy.addFilter(.blur(radius: rect.height / 3 * dissolve)) }
                    }
                    if zoom != 1 {
                        copy.translateBy(x: rect.midX, y: rect.midY)
                        copy.scaleBy(x: zoom, y: zoom)
                        copy.translateBy(x: -rect.midX, y: -rect.midY)
                    }
                    if let tint {
                        // The letter's own shape, filled with the picture's colour.
                        copy.clipToLayer { layer in layer.draw(slice, options: .disablesSubpixelQuantization) }
                        copy.fill(Path(rect.insetBy(dx: -rect.width, dy: -rect.height)),
                                  with: .color(Color(.sRGB, red: Double(tint.x), green: Double(tint.y), blue: Double(tint.z))))
                    } else {
                        copy.draw(slice, options: .disablesSubpixelQuantization)
                    }
                }
            }
        }
    }
}

/// The timing of the letters' gathering into the picture, shared by the letters and the mask that reveals the picture
/// where they land: after a short pause they set off one after another in reading order, each flying for the same
/// time.
nonisolated enum Gather {
    static let start = 0.1
    static let stagger = 0.35
    static let flight = 0.45

    /// Seconds since this letter set off (negative before), by its place in the text (0...1).
    static func elapsed(_ gone: TimeInterval, fraction: Double, jitter: Double) -> TimeInterval {
        gone - start - stagger * fraction - 0.05 * jitter
    }

    /// How far along its flight a letter is, eased out: 0 at rest, 1 landed.
    static func arrival(_ gone: TimeInterval, fraction: Double, jitter: Double) -> Double {
        let t = elapsed(gone, fraction: fraction, jitter: jitter)
        return t <= 0 ? 0 : 1 - pow(1 - min(t / flight, 1), 2)
    }

    /// How far the picture has formed at the point a letter lands on: a patch that grows as the letter comes down.
    static func patch(_ gone: TimeInterval, fraction: Double) -> Double {
        Easing.smooth((elapsed(gone, fraction: fraction, jitter: 0.5) - flight + 0.12) / 0.3)
    }
}

/// Easing shared by the timeline-driven views.
nonisolated enum Easing {
    /// 0 before `t` reaches 0, 1 once it reaches 1, eased in and out between.
    static func smooth(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The system's `.smooth` spring (critically damped) of the given duration, from rest, `t` seconds in: quick to
    /// leave and long to settle, the curve the wall's cards slide on. Within half a percent of 1 by 1.2 durations.
    static func spring(_ t: Double, duration: Double = 0.5) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / duration
        return 1 - (1 + w * t) * exp(-w * t)
    }
}
