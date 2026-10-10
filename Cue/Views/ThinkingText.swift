import SwiftUI

/// AI at work on an answer, until its first words come: the word in grey, a darker light passing over it again and
/// again (picked by the user from four on 2026-10-07). Tried before it: a ring of dots after Siri's ("做得太他妈丑了"),
/// then the word floating on the swell of the words waiting for a picture ("这肯定不是要这个波浪呀"). It shows once the
/// question has gone up to its place, so as not to move with it.
struct ThinkingText: View {
    @State private var start = Date.now
    @State private var shown = false
    private let text = String(localized: "Thinking")

    var body: some View {
        TimelineView(.animation) { context in
            // Across the word once every 1.8 s. The light, 70% of the word's width, is wholly off the word at both
            // ends of its run, so it starts again unseen.
            let phase = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.8) / 1.8
            Text(text)
                .foregroundStyle(.tertiary)
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.7)
                            .offset(x: -width * 0.7 + width * 1.7 * phase)
                    }
                    .mask(Text(text))
                }
        }
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
        }
    }
}
