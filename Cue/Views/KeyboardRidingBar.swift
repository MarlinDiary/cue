import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A bar that rides the keyboard exactly: UIKit places it on its keyboard layout guide, which moves in the keyboard's
/// own animation, drawn by the render server frame for frame with the keys, and under a finger dragging the keyboard
/// down. Nothing SwiftUI does for the keyboard matched it (measured in the simulator, 2026-10-08): its own keyboard
/// avoidance moves the safe area on a curve of its own (a bar on it ran 14 pt ahead of the keys), a spring of our own
/// fell 20 pt behind, and following the keyboard from the main thread set off two frames late, the main thread being
/// busiest just as a keyboard comes.
///
/// The bar's bottom stands `raisedGap` above the keys, or `restingGap` above the bottom of the safe area (negative:
/// below it, into the home indicator's room, as the system's own field stands), whichever is higher: so it rests while
/// the keyboard is away, and rides the keys once they come up past its resting place. Where it stands is the guide's
/// alone, laid out for the keyboard's end inside the keyboard's animation, so it goes from the one place to the other
/// with the keys. (Switched from the one gap to the other as the keyboard's notifications came, the bar jumped by the
/// difference, 14.5 pt, as the keyboard set off: UIKit lays the guide out in the keyboard's animation before it tells of
/// the keyboard, and the switch was laid out after it, out of the animation; measured in the simulator, 2026-10-09.)
///
/// `onTouch` is told as a finger comes down on the bar, before anything the touch does: before a keyboard it calls up
/// takes the main thread (~150 ms on the phone), so what scrolls behind can be stopped first rather than stopped dead
/// by it and thrown on after.
///
/// `fillsAbove` centres the content between `top` points below the top of the screen and where the bar's bottom would
/// stand instead, for what stands centred over the bar and the keyboard (an empty conversation's placeholder); it lets
/// every touch through. The content keeps its own size and only moves, in the keyboard's animation: stretched over the
/// space, it was laid out again by SwiftUI for the keyboard's end at once, and jumped there ahead of the keyboard.
struct KeyboardRidingBar<Content: View>: UIViewRepresentable {
    var restingGap: CGFloat
    var raisedGap: CGFloat
    var fillsAbove = false
    var top: CGFloat = 0
    var onTouch: () -> Void = {}
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> Container {
        let container = Container(restingGap: restingGap, raisedGap: raisedGap, fillsAbove: fillsAbove)
        container.onTouch = onTouch
        let hosting = UIHostingController(rootView: content())
        hosting.view.backgroundColor = .clear
        // The bar reaches into the home indicator's safe area on purpose, and the keyboard is its own affair: left
        // to itself, the hosted view kept its content out of both (the bar stood 6.5 pt too high at rest).
        hosting.safeAreaRegions = []
        container.mount(hosting)
        return container
    }

    /// The window's width from the first frame, as the conversation's column has: the page comes up widening from
    /// nothing (iOS 27), and offered the width it had, the container stood 44 pt wide (the scroll view's margins) until
    /// the keyboard came, so an empty conversation's bar and placeholder came up in a 44 pt column, the title broken over
    /// five lines, and spread out to the screen's width in the keyboard's animation, sliding in from the right (measured
    /// in the simulator, 2026-10-09).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let window = uiView.window?.bounds.size ?? UIScreen.main.bounds.size
        return CGSize(width: window.width, height: proposal.height ?? window.height)
    }

    func updateUIView(_ container: Container, context: Context) {
        container.onTouch = onTouch
        container.top?.constant = top
        container.hosting?.rootView = content()
        container.fitHeight()
    }

    /// The whole screen, letting touches through everywhere but the bar.
    final class Container: UIView {
        var hosting: UIHostingController<Content>?
        var onTouch: () -> Void = {}
        /// Where filled content begins, below the top of the screen.
        var top: NSLayoutConstraint?
        private let restingGap: CGFloat
        private let raisedGap: CGFloat
        private let fillsAbove: Bool

        init(restingGap: CGFloat, raisedGap: CGFloat, fillsAbove: Bool) {
            self.restingGap = restingGap
            self.raisedGap = raisedGap
            self.fillsAbove = fillsAbove
            super.init(frame: .zero)
            backgroundColor = .clear
            let touch = TouchDown()
            touch.action = { [weak self] in self?.onTouch() }
            addGestureRecognizer(touch)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The hosted view's height: what the content takes at the screen's width. Sized by its intrinsic size, the
        /// content was measured as if the screen were endlessly wide, and a field of several lines stayed one line tall.
        private var height: NSLayoutConstraint?

        func mount(_ hosting: UIHostingController<Content>) {
            self.hosting = hosting
            let view = hosting.view!
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            // Its height from the first: at no height, the field in it couldn't take the keyboard as the page opened.
            let fitting = hosting.sizeThatFits(in: CGSize(width: UIScreen.main.bounds.width,
                                                          height: .greatestFiniteMagnitude)).height
            let height = view.heightAnchor.constraint(equalToConstant: fitting)
            height.isActive = true
            self.height = height
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            // The bottom of what is placed: the bar's own, or that of the space its content is centred in.
            let edge: NSLayoutYAxisAnchor
            if fillsAbove {
                let space = UILayoutGuide()
                addLayoutGuide(space)
                let top = space.topAnchor.constraint(equalTo: topAnchor)
                NSLayoutConstraint.activate([top, view.centerYAnchor.constraint(equalTo: space.centerYAnchor)])
                self.top = top
                edge = space.bottomAnchor
            } else {
                edge = view.bottomAnchor
            }
            // The keys' top, or the screen's bottom with the keyboard away, not the safe area's: the resting place is
            // the second bound below.
            keyboardLayoutGuide.usesBottomSafeArea = false
            // As low as both bounds let it be.
            let low = edge.constraint(equalTo: bottomAnchor)
            low.priority = .defaultLow
            NSLayoutConstraint.activate([
                edge.constraint(lessThanOrEqualTo: keyboardLayoutGuide.topAnchor, constant: -raisedGap),
                edge.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -restingGap),
                low,
            ])
        }

        override func layoutSubviews() {
            fitHeight()
            super.layoutSubviews()
        }

        func fitHeight() {
            guard let hosting, bounds.width > 0 else { return }
            let fitting = hosting.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            if abs((height?.constant ?? 0) - fitting) > 0.5 { height?.constant = fitting }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !fillsAbove, let view = hosting?.view, view.frame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }
}

/// Tells of a finger coming down, and stands aside at once: it never recognizes, so every other gesture and control
/// under the finger goes on as if it weren't there.
private final class TouchDown: UIGestureRecognizer {
    var action: () -> Void = {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        action()
        state = .failed
    }
}
