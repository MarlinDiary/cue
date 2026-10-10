import SwiftUI

/// A word's picture, and in its place while it is being drawn, the description it is drawn from, typed out; when the
/// picture arrives the letters gather into its shape and it forms where they land. It fills the room its card or page
/// gives it, the same fixed room on both (the page's is the card's, scaled to the page), so nothing moves when the
/// picture arrives: the trimmed picture is centred in the room at a size set by its area, as on the card.
struct WordPicture: View {
    let word: Word
    var area: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    /// For a new word, the arrival of its headword, meaning and idea in turn: the idea comes in only once the pieces
    /// before it have.
    var schedule: TypingSchedule?

    private var illustrator: Illustrator { .shared }
    private var lexicographer: Lexicographer { .shared }
    /// Where the text and the room are, so the letters know where the picture's edge is.
    @State private var textFrame: CGRect = .zero
    @State private var roomSize: CGSize = .zero

    /// Whether there is a picture to show, or one on its way, so a card or page keeps room for it.
    static func isShown(for word: Word) -> Bool {
        word.imageData != nil || isComing(for: word)
    }

    /// A picture is on its way while it is being drawn, while the entry that will describe it is being written, and from
    /// then until it is in: one that didn't come is drawn again, its words waiting in its place meanwhile (user,
    /// 2026-10-07: "在图片出来之前，任何情况之下，这个波浪的文字都不能丢").
    static func isComing(for word: Word) -> Bool {
        if Illustrator.shared.isDrawing(word) { return true }
        guard word.imageData == nil, AIAccess.isAvailable else { return false }
        return Lexicographer.shared.isWriting(word) || Illustrator.shared.idea(for: word) != nil
            || word.entry?.pictureIdea != nil
    }

    /// Whether the finished picture is on show (or coming up), rather than the words standing in for it.
    static func showsPicture(for word: Word) -> Bool {
        word.imageData != nil && !Illustrator.shared.isDrawing(word)
    }

    var body: some View {
        let picture = Self.showsPicture(for: word) ? PictureCache.image(for: word) : nil
        // What the picture was first drawn from, from then until it is in, whatever brief a later try draws it from;
        // before that, the idea as soon as the entry has it.
        let idea = illustrator.idea(for: word) ?? word.entry?.pictureIdea ?? lexicographer.draft(for: word)?.pictureIdea
        let started = illustrator.started(for: word)
        let finished = illustrator.finished(for: word)
        let trace = illustrator.trace(for: word)
        // The picture's size, and where it will sit in the room, in the text's own coordinates.
        let pictureSize = picture.map {
            Illustration.displaySize(aspect: $0.size.width / max($0.size.height, 1), area: area, maxWidth: maxWidth,
                                     maxHeight: maxHeight)
        } ?? .zero
        let pictureRect = CGRect(x: (roomSize.width - pictureSize.width) / 2 - textFrame.minX,
                                 y: (roomSize.height - pictureSize.height) / 2 - textFrame.minY,
                                 width: pictureSize.width, height: pictureSize.height)
        let side = area.squareRoot()
        // 1 on a card; the page is about twice that, and its blurs grow less than that.
        let s = side / 10_700.squareRoot()
        let k = min(s, 1.6)
        // Nothing moves once the picture is in and settled, or before there is anything to show; the words waiting for
        // it float on their swell all the while, between one try and the next too.
        let still = picture != nil ? finished == nil : idea == nil
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { context in
            let now = context.date
            // Seconds since the words began coming in: a new word's by its schedule, a redrawn picture's since the
            // drawing began. Words already in place when the app started, for a picture still owed, came in long ago.
            let shown = schedule?.shown(2, at: now) ?? started.map { now.timeIntervalSince($0) }
                ?? now.timeIntervalSince(.distantPast)
            let gone: TimeInterval = finished.map { now.timeIntervalSince($0) } ?? (picture != nil ? 1000 : -1)
            // The picture forms where the letters land (`WordsRenderer` flies them, on `Gather`'s timing): it is
            // revealed in a soft patch at each landing point, whole once the last has landed, and sharp by then.
            let went = Easing.smooth((gone - 0.9) / 0.4), sharp = Easing.smooth(gone / 1.2)
            let whole = Easing.smooth((gone - Gather.start - Gather.stagger - Gather.flight + 0.1) / 0.3)
            ZStack {
                if let picture, gone > 0 {
                    Illustration(image: picture, area: area, maxWidth: maxWidth, maxHeight: maxHeight)
                        .scaleEffect(0.98 + 0.02 * sharp)
                        .blur(radius: 3 * k * (1 - sharp))
                        .mask {
                            Canvas { canvas, size in
                                guard let trace else {
                                    return canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                                }
                                let n = trace.interior.count
                                let frame = CGRect(x: (size.width - pictureSize.width) / 2, y: 0,
                                                   width: pictureSize.width, height: pictureSize.height)
                                let radius = 1.7 * (frame.width * frame.height * trace.coverage / CGFloat(max(n, 1))).squareRoot()
                                for (j, u) in trace.interior.enumerated() {
                                    let r = radius * Gather.patch(gone, fraction: Double(j) / Double(max(n - 1, 1)))
                                    guard r > 0 else { continue }
                                    let c = CGPoint(x: frame.minX + u.x * frame.width, y: frame.minY + u.y * frame.height)
                                    canvas.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                                with: .color(.black))
                                }
                                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(whole)))
                            }
                            .blur(radius: 3 * k)
                        }
                }
                if let idea, went < 1 {
                    // The words are only here while their picture is on its way, so they always show the wait.
                    // Set as on a card at any size, the page's only larger, in the same lines (user, 2026-10-07: "应该
                    // 跟卡片的布局一模一样，但是可能就是字体大一点…不应该是本来在卡片上显示是五六行的，然后点进去之后一看
                    // 显示只剩三行了"): the page used to cap the size and widen the measure, and fitted the words in half
                    // as many lines. A card's measure is its picture's room, less a little.
                    TypedIdea(text: idea, shown: shown, fontSize: 12.5 * s,
                              width: 0.94 * (CardMetrics.baseWidth - 40) * s,
                              gone: gone, trace: trace, pictureRect: pictureRect, waiting: true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("room")) } action: { textFrame = $0 }
                        .frame(maxWidth: .infinity)
                        .opacity(1 - went)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named("room"))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { roomSize = $0 }
        }
    }
}

/// Decoded pictures, kept so a card that is redrawn several times a second while a word streams in doesn't decode its
/// picture again each time.
enum PictureCache {
    private static var images: [UUID: (data: Data, image: UIImage)] = [:]

    static func image(for word: Word) -> UIImage? {
        guard let data = word.imageData else { return nil }
        if let cached = images[word.id], cached.data == data { return cached.image }
        guard let image = UIImage(data: data) else { return nil }
        images[word.id] = (data, image)
        return image
    }
}
