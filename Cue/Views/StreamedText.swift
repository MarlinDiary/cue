import SwiftUI

/// An answer as AI writes it. Its words come over the network in bursts, a dozen characters and then nothing for a
/// tenth of a second, so each burst is spread over about as long as the last one took to come, and each character
/// comes into focus as words do everywhere in the app (`WordsRenderer`), only quicker: the answer flows on at the pace
/// it is written instead of jumping a dozen characters at a time.
struct StreamedText: View {
    let text: String
    /// Whether more is coming. Text there before it began comes in at once.
    var writing: Bool

    /// When each character comes in, by its place in the text's UTF-16 (as the text's layout counts characters), in
    /// seconds since the reference date.
    @State private var times: [TimeInterval] = []
    /// When the last burst came.
    @State private var lastBurst: TimeInterval = 0
    /// Whether every character is in and nothing more is coming: the text is then one to select words in.
    @State private var settled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lines set as `SelectableText` sets them, so the answer doesn't move as it turns into one once written.
    @ScaledMetric(relativeTo: .body) private var lineHeight = SelectableText.lineHeight

    init(text: String, writing: Bool) {
        self.text = text
        self.writing = writing
        _settled = State(initialValue: !writing)
    }

    var body: some View {
        // Made once for each change of the text, outside the timeline, so its Chinese and English aren't split apart
        // again on every frame.
        let mixed = MixedText(text).lineHeight(.exact(points: lineHeight))
        if !writing && (settled || reduceMotion) {
            // Written and still: words in it can be selected (`SelectableText`).
            SelectableText(text: text)
        } else if reduceMotion {
            // With Reduce Motion on, the text simply grows as it comes.
            mixed
        } else {
            TimelineView(.animation(paused: settled)) { context in
                mixed.textRenderer(StreamRenderer(times: times, paragraphs: paragraphs,
                                                  now: context.date.timeIntervalSinceReferenceDate))
            }
            .onChange(of: text.utf16.count, initial: true) { arrived(making: text.utf16.count) }
            .task(id: writing) {
                guard !writing else { settled = false; return }
                let rest = (times.last ?? 0) + StreamRenderer.fade - Date.now.timeIntervalSinceReferenceDate
                if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
                if !Task.isCancelled { settled = true }
            }
        }
    }

    /// Where each paragraph with characters in it begins, in UTF-16.
    private var paragraphs: [Int] {
        var starts: [Int] = []
        var start = 0
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            if offset > start { starts.append(start) }
            start = offset + 1
        }
        if text.utf16.count > start { starts.append(start) }
        return starts
    }

    /// Characters have just come, making the text `total` long.
    private func arrived(making total: Int) {
        let count = total - times.count
        guard count > 0 else { return }
        // Already there: in at once.
        guard writing else {
            times += Array(repeating: 0, count: count)
            return
        }
        let now = Date.now.timeIntervalSinceReferenceDate
        settled = false
        // Spread over the time since the last burst, between 20 and 200 ms; and never more than 0.3 s behind what has
        // come.
        let start = max(now, times.last ?? 0)
        let span = start - now > 0.3 ? 0.02 : min(max(now - lastBurst, 0.02), 0.2)
        times += (1...count).map { start + span * Double($0) / Double(count) }
        lastBurst = now
    }
}

/// Draws each character of a streamed answer once its time has come, coming into focus over a quarter of a second:
/// from a soft blur and nothing to sharp and full, as `WordsRenderer` brings words in, without the lift.
nonisolated struct StreamRenderer: TextRenderer {
    var times: [TimeInterval]
    /// Where each paragraph with characters in it begins in the text, in UTF-16.
    var paragraphs: [Int]
    var now: TimeInterval

    static let fade = 0.25

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The layout counts characters from the start of each paragraph (measured: the line after a blank one
        // began at 0 again), so the paragraphs are counted off as their lines go by, a line beginning no further on
        // than the last one ended being a new paragraph's, and each character's place in the whole text found from
        // its paragraph's start. Paragraphs with no characters have no runs, and are not counted.
        guard let zero = layout.first?.first?.characterIndices.first else { return }
        var paragraph = 0
        var last = -1
        for line in layout {
            guard let begin = line.first?.characterIndices.first else { continue }
            if zero.distance(to: begin) <= last, paragraph + 1 < paragraphs.count {
                paragraph += 1
                last = -1
            }
            let start = paragraphs.isEmpty ? 0 : paragraphs[paragraph]
            for run in line {
                if let end = run.characterIndices.last { last = max(last, zero.distance(to: end)) }
                // A run all in draws whole.
                if let end = run.characterIndices.last, progress(start + zero.distance(to: end)) >= 1 {
                    context.draw(run)
                    continue
                }
                for slice in run {
                    guard let index = slice.characterIndices.first else { continue }
                    let p = progress(start + zero.distance(to: index))
                    guard p > 0 else { continue }
                    let eased = 1 - (1 - p) * (1 - p)
                    var copy = context
                    copy.opacity = eased
                    if p < 1 { copy.addFilter(.blur(radius: slice.typographicBounds.rect.height / 4 * (1 - eased))) }
                    copy.draw(slice)
                }
            }
        }
    }

    /// How far in the character at `index` is: 0 before its time, 1 once in.
    private func progress(_ index: Int) -> Double {
        guard index < times.count else { return 0 }
        return min(max((now - times[index]) / Self.fade, 0), 1)
    }
}

/// Takes text out of sight, each character in turn as it was written, going out of focus as it fades: the way words
/// come in (`StreamRenderer`), the other way. `elapsed`: seconds since it began.
nonisolated struct VanishRenderer: TextRenderer {
    var elapsed: TimeInterval

    /// From the first character setting off to the last, and how long each takes to go.
    static let spread = 0.35
    static let fade = 0.25
    static var duration: TimeInterval { spread + fade }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = max(layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }, 1)
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let p = min(max((elapsed - Self.spread * Double(index) / Double(total)) / Self.fade, 0), 1)
                    index += 1
                    guard p < 1 else { continue }
                    let eased = p * p
                    var copy = context
                    copy.opacity = 1 - eased
                    if p > 0 { copy.addFilter(.blur(radius: slice.typographicBounds.rect.height / 4 * eased)) }
                    copy.draw(slice)
                }
            }
        }
    }
}
