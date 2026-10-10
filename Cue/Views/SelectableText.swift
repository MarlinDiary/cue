import SwiftUI
import UIKit

/// An answer in the conversation: `MixedText` as it is set there, every line `lineHeight` tall, whose words can be
/// selected with a long press, with the system's handles and menu (Copy, Look Up, Translate, Share), as text is in
/// Notes and Safari (user, 2026-10-08: "如果我们长按回复过来的文字，我们应该是处于一个选中的状态"). SwiftUI's own text can
/// be selected on iOS only as a whole, so the answer long-pressed turns, for as long as something in it is selected,
/// into UIKit's text view set the same way, line for line, the word under the finger selected. The rest of the time
/// it is SwiftUI's text, light to lay out: answers that were all text views took up to 12 ms each to make as they
/// scrolled in, and the conversation dropped frames (user, 2026-10-08: "AI那边往下滑的时候，总感觉有点掉帧").
struct SelectableText: View {
    let text: String

    /// How tall every line of an answer is, before the 4 pt between lines, at the default text size, set alike in
    /// SwiftUI's text and UIKit's, so an answer doesn't move as it turns from one to the other. Left to themselves,
    /// UIKit took the line's height from its tallest font and SwiftUI from the text's own, so lines with Chinese in
    /// them stood 2 pt further apart in UIKit's.
    static let lineHeight: CGFloat = 22

    @ScaledMetric(relativeTo: .body) private var lineHeight = SelectableText.lineHeight
    /// Where the long press began that is selecting words in the text, while it is.
    @State private var selecting: CGPoint?

    var body: some View {
        MixedText(text)
            .lineHeight(.exact(points: lineHeight))
            .opacity(selecting == nil ? 1 : 0)
            .overlay {
                if let selecting {
                    TextView(text: text, start: selecting) { self.selecting = nil }
                }
            }
            .gesture(LongPress { selecting = $0 })
            .sensoryFeedback(.selection, trigger: selecting != nil) { _, now in now }
    }

    /// A long press, with where it began.
    private struct LongPress: UIGestureRecognizerRepresentable {
        var onPress: (CGPoint) -> Void

        func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
            let recognizer = UILongPressGestureRecognizer()
            recognizer.minimumPressDuration = 0.4
            return recognizer
        }

        func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
            if recognizer.state == .began { onPress(context.converter.localLocation) }
        }
    }

    /// UIKit's text view, for selecting: it selects the word at `start` and shows the menu for it as it comes, and goes
    /// (`onEnd`) once nothing in it is selected, or it gives up the focus.
    private struct TextView: UIViewRepresentable {
        var text: String
        var start: CGPoint
        var onEnd: () -> Void

        func makeUIView(context: Context) -> Selecting {
            let view = Selecting(usingTextLayoutManager: true)
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.dataDetectorTypes = []
            // Lines as tall as they are set and no taller: with its fonts' leading on top, a line stood 1.5 pt taller
            // than SwiftUI's.
            view.textLayoutManager?.usesFontLeading = false
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.attributedText = Self.attributed(MixedText.pieces(of: text), size: context.environment.dynamicTypeSize)
            view.delegate = context.coordinator
            view.onResign = { context.coordinator.onEnd() }
            context.coordinator.onEnd = onEnd
            // Once it is in the window.
            DispatchQueue.main.async { context.coordinator.select(at: start, in: view) }
            return view
        }

        func updateUIView(_ view: Selecting, context: Context) {
            context.coordinator.onEnd = onEnd
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: Selecting, context: Context) -> CGSize? {
            guard let width = proposal.width, width.isFinite else { return nil }
            let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fitted.height))
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        /// The text as `MixedText` sets it in an answer: the body font, English in the serif, every line
        /// `SelectableText.lineHeight` tall and 4 pt apart.
        static func attributed(_ pieces: [MixedText.Piece], size: DynamicTypeSize) -> NSAttributedString {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let serif = body.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 0) } ?? body
            let height = UIFontMetrics(forTextStyle: .body).scaledValue(for: SelectableText.lineHeight,
                                                                       compatibleWith: traits)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.lineSpacing = 4
            // Lines broken where SwiftUI breaks them: without it, "话吗？" was split before "吗？".
            paragraph.lineBreakStrategy = .standard
            // SwiftUI centres the text in a line taller than its font's, UIKit sets it at the line's foot: raised by
            // half the difference, the letters stand where SwiftUI's do (0.85 pt lower otherwise).
            let raise = (height - body.lineHeight) / 2
            let result = NSMutableAttributedString()
            for piece in pieces {
                result.append(NSAttributedString(string: piece.text, attributes: [
                    .font: piece.isEnglish ? serif : body,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                    .baselineOffset: raise,
                ]))
            }
            return result
        }

        /// A text view that says when it gives up the focus, as when the field is tapped.
        final class Selecting: UITextView {
            var onResign: () -> Void = {}

            override func resignFirstResponder() -> Bool {
                let resigned = super.resignFirstResponder()
                if resigned { onResign() }
                return resigned
            }
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var onEnd: () -> Void = {}

            /// Selects the word at `point` and shows the system's menu for it, as a long press on text does.
            func select(at point: CGPoint, in view: UITextView) {
                guard let position = view.closestPosition(to: point),
                      let word = view.tokenizer.rangeEnclosingPosition(position, with: .word,
                                                                      inDirection: .storage(.forward))
                        ?? view.tokenizer.rangeEnclosingPosition(position, with: .word,
                                                                 inDirection: .storage(.backward))
                else { return onEnd() }
                view.becomeFirstResponder()
                view.selectedTextRange = word
                // The text view's own menu shows only for a selection made by hand; this one offers what it would,
                // from the text view, which has the focus and the selection.
                let rect = view.firstRect(for: word)
                let menu = UIEditMenuInteraction(delegate: nil)
                view.addInteraction(menu)
                menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                                   sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
            }

            /// Nothing selected any more, as after a tap: back to SwiftUI's text.
            func textViewDidChangeSelection(_ view: UITextView) {
                if view.selectedRange.length == 0 { onEnd() }
            }
        }
    }
}
