import SwiftUI
import UIKit

/// Finds the UIKit scroll view a SwiftUI `ScrollView` is drawn in, from inside its content, for what SwiftUI can't do
/// with it: stopping a glide at once, and moving the content in the keyboard's own animation. SwiftUI's scrolling runs
/// on the main thread, which a keyboard coming holds for ~150 ms (on the phone): a scroll SwiftUI animated beside the
/// keyboard stood still all that while and then jumped to its end.
struct ScrollViewProbe: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Probe {
        Probe(found: found)
    }

    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        private let found: (UIScrollView) -> Void

        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let candidate = view, !(candidate is UIScrollView) { view = candidate.superview }
            if let scrollView = view as? UIScrollView { found(scrollView) }
        }
    }
}

extension UIScrollView {
    /// Stops a glide where it is.
    func hold() {
        setContentOffset(contentOffset, animated: false)
    }

    /// How far down the content can be scrolled.
    var end: CGFloat {
        contentSize.height + adjustedContentInset.bottom - bounds.height
    }

    /// Scrolls to `y` in the animation of the keyboard notification `note` (its duration and curve), drawn by the render
    /// server with the keyboard however busy the main thread is.
    func scroll(to y: CGFloat, alongKeyboard note: Notification) {
        scroll(to: y, along: KeyboardMotion(note))
    }

    func scroll(to y: CGFloat, along motion: KeyboardMotion) {
        UIView.animate(withDuration: motion.duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: motion.curve << 16), .beginFromCurrentState]) {
            self.contentOffset.y = y
        }
    }
}

/// How the keyboard moves, as a keyboard notification tells it: for what goes with it.
struct KeyboardMotion: Sendable {
    var duration: Double
    var curve: UInt

    init(_ note: Notification) {
        duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.38
        curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
    }
}

/// Keeps a glide going while the main thread is held, a keyboard coming (~150 ms on the phone, the system's own work):
/// UIKit's glide is moved on the main thread, so it stood still all that while and then jumped to where the time had
/// brought it (user, 2026-10-09: "首页卡片滚动的时候软键盘弹出会卡"; stopping it instead was "很奇怪", and the wanted
/// answer was "继续滑动，但不顿一下").
///
/// Told before the hold (a finger coming down on the bar), the carrier takes the glide over from UIKit: it stops UIKit's
/// and draws the rest of it, to where it comes to rest, on the render server, along the curve UIKit's was following
/// (from UIKit's own speed as the finger let go, read off SwiftUI's scroll target, or else fitted to how the glide had
/// just moved), so neither the keyboard's hold nor anything after it on the main thread can stop it; the scroll view's
/// own offset follows the same curve frame by frame underneath, for what SwiftUI shows and keeps of the wall. What
/// comes into sight during the hold is laid out only after it: the lazy wall shows nothing there until then. The same
/// as a finger lets go and takes the keyboard down (`carryRelease`). Handing the glide back to UIKit after the hold, as it first did, left a step: after a hold
/// UIKit's glide jumps on and then runs off the curve it was on (seen on the phone: 5 pt off 0.4 s later); drawn ahead
/// only through the hold, the glide stopped again at every later stall of the main thread (in the simulator: 20–50 ms,
/// four times as the keyboard came).
@MainActor
final class GlideCarrier: NSObject {
    private weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?
    /// The glide's last positions, with when the main thread saw them.
    private var samples: [(time: CFTimeInterval, y: CGFloat)] = []

    /// The glide taken over.
    private var curve: Curve?
    private var link: CADisplayLink?
    /// Whether the carrier is setting the scroll view's offset itself, which the samples leave out.
    private var moving = false
    /// When the keyboard last set off down, and how it goes.
    private var keyboardWent = -CFTimeInterval.infinity
    private var keyboardMotion: KeyboardMotion?
    /// How fast UIKit's glide sets off as a finger lets go, in points a second, and when (`GlideTargetReader`); and
    /// when a finger last moved the scroll view, for whether that glide is the one going on.
    private var setOff: (speed: Double, time: CFTimeInterval)?
    private var lastTracked = -CFTimeInterval.infinity
    private var keyboardObserver: NSObjectProtocol?
    private static let key = "carriedGlide"

    /// A glide: y(t) = a + b·e^(k·(t − t0)), coming to rest at a, as UIKit's slows by its deceleration rate every
    /// millisecond; or, running into an edge before that (`edge`, at time `hit`, going `speed`), from there UIKit's
    /// spring at its edges: y = edge + speed·τ·e^(−ω·τ), τ = t − hit, out past the edge and back.
    private struct Curve {
        var a: Double, b: Double, k: Double, t0: CFTimeInterval
        var edge: Double?
        var hit = CFTimeInterval.infinity
        var speed = 0.0

        /// UIKit's spring at a scroll view's edges, measured on the phone (a glide into the wall's top, 2026-10-09):
        /// critically damped, ω ≈ 12/s, from the speed the glide got there with (at 200 pt/s, 6 pt out and back in
        /// 0.4 s; fitted to within half a point); a scroll view pulled past its top springs back on it from rest.
        static let ω = 12.0

        /// The glide from `y` at `t0`, at `speed` points a second, with edges at `top` and, if it is given, `end`.
        init(from y: Double, speed: Double, k: Double, t0: CFTimeInterval, top: Double, end: Double?) {
            b = speed / k
            a = y - b
            self.k = k
            self.t0 = t0
            let edge = a < top ? top : end.flatMap { a > $0 ? $0 : nil }
            // Where it gets to the edge, how soon (e^(k·(hit − t0)) = (edge − a) / b) and how fast.
            if let edge, case let part = (edge - a) / b, part > 0, part <= 1 {
                self.edge = edge
                hit = t0 + log(part) / k
                self.speed = k * (edge - a)
            }
        }

        func position(at t: CFTimeInterval) -> Double {
            guard let edge, t >= hit else { return a + b * exp(k * (t - t0)) }
            let τ = t - hit
            return edge + speed * τ * exp(-Self.ω * τ)
        }

        /// Where it comes to rest, and when: within a third of a point of there.
        var rest: Double { edge ?? a }

        var stop: CFTimeInterval {
            guard edge != nil else { return t0 + log(0.3 / max(abs(b), 0.3)) / k }
            var τ = 1 / Self.ω
            while abs(speed) * τ * exp(-Self.ω * τ) >= 0.3 { τ += 0.004 }
            return hit + τ
        }
    }

    init(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        observation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.note(scrollView) }
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] note in
            let motion = KeyboardMotion(note)
            MainActor.assumeIsolated {
                self?.keyboardWent = CACurrentMediaTime()
                self?.keyboardMotion = motion
            }
        }
    }

    isolated deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    }

    private func note(_ scrollView: UIScrollView) {
        guard !moving else { return }
        if scrollView.isTracking { lastTracked = CACurrentMediaTime() }
        guard scrollView.isDecelerating, !scrollView.isTracking else {
            samples.removeAll()
            return
        }
        samples.append((CACurrentMediaTime(), scrollView.contentOffset.y))
        if samples.count > 6 { samples.removeFirst() }
    }

    /// Takes the glide over, if the scroll view is gliding between its ends, to rest short of its end or to run into its
    /// top and spring back there; taken over already, it goes on as it is. Not one running into its end: the end moves
    /// as the keyboard's room comes in. Not as it springs back from beyond an end: that is no glide, and fitted as one,
    /// it came to rest 28 pt short of the top it was going back to.
    func carry() {
        guard curve == nil, let scrollView, scrollView.isDecelerating else { return }
        let top = -scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y
        guard y >= top, y <= scrollView.end else { return }
        // How fast it goes now: from UIKit's own speed as the finger let go, slowed for the time since, or else fitted to
        // its last frames (a finger coming down on the bar right after the fling had none yet, and it was left to UIKit).
        let k = 1000 * log(Double(scrollView.decelerationRate.rawValue))
        let now = CACurrentMediaTime()
        let speed: Double
        if let setOff, setOff.time >= lastTracked {
            speed = setOff.speed * exp(k * (now - setOff.time))
        } else if let fitted = fit(scrollView) {
            speed = fitted.speed * exp(k * (now - fitted.t0))
        } else {
            return
        }
        let curve = Curve(from: Double(y), speed: speed, k: k, t0: now, top: Double(top), end: nil)
        guard curve.rest < Double(scrollView.end) else { return }
        take(curve)
    }

    /// Takes the motion over as the finger lets go with the keyboard going down (set off down in the last quarter of a
    /// second: in a drag that takes it down, the keyboard sets off as the finger lets go), whose putting away holds the main thread
    /// (~40 ms on the phone) just as UIKit's glide or spring back sets off: the wall stood still that long, then jumped
    /// on by 31 pt (user, 2026-10-09, a screen recording: "还是有不自然的地方"). Pulled past the top, the scroll view
    /// springs back on the render server, on UIKit's spring at the edges (`Curve.ω`), from rest, as UIKit's does;
    /// otherwise it glides on as UIKit's would from how fast the finger was moving it, and springs back at the top or at
    /// `end` if it runs into them, `end` being where its end will be once the keyboard's room has gone. Let go of short
    /// of that end, the finger having brought it down less far than the keyboard goes, it comes down to the end with the
    /// keyboard, as from a still finger, its end over the bar as the bar comes down; flung on past that end, it is left
    /// to UIKit.
    func carryRelease(end: CGFloat) {
        guard CACurrentMediaTime() - keyboardWent < 0.25 else { return }
        #if DEBUG
        KeyboardHold.afterRelease()
        guard KeyboardHold.carries else { return }
        #endif
        guard curve == nil, let scrollView, !scrollView.isTracking else { return }
        let top = -scrollView.adjustedContentInset.top
        let y = scrollView.contentOffset.y
        if y < top {
            setOff = nil
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            UIView.animate(springDuration: 2 * .pi / Curve.ω, bounce: 0) { scrollView.contentOffset.y = top }
            CATransaction.flush()
            return
        }
        // UIKit's own speed, as it set off just now: the gesture's had been reset by now, and its last as the finger
        // moved, or one worked out from the offsets, came out up to a fifth slower, the glide slowing all at once.
        let speed = setOff.flatMap { $0.time >= lastTracked && CACurrentMediaTime() - $0.time < 0.1 ? $0.speed : nil }
        let k = 1000 * log(Double(scrollView.decelerationRate.rawValue))
        if y > end {
            guard let keyboardMotion, Double(y) - (speed ?? 0) / k >= Double(end) else { return }
            setOff = nil
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            scrollView.scroll(to: end, along: keyboardMotion)
            CATransaction.flush()
            return
        }
        guard let speed else { return }
        take(Curve(from: Double(y), speed: speed, k: k, t0: CACurrentMediaTime(), top: Double(top), end: Double(end)))
    }

    /// How fast UIKit's glide sets off as a finger lets go, in points a millisecond, as SwiftUI tells its scroll target
    /// behaviours.
    func noteSetOff(speed: CGFloat) {
        // Only as the finger lets go, before UIKit's glide is under way: asked again on its every frame, and on the
        // carrier's, SwiftUI gave the speed it had set off with.
        guard curve == nil, let scrollView, !scrollView.isDecelerating else { return }
        setOff = (Double(speed) * 1000, CACurrentMediaTime())
    }

    /// Stops UIKit's glide and goes on along `curve` from the same place.
    private func take(_ curve: Curve) {
        guard let scrollView else { return }
        self.curve = curve
        samples.removeAll()
        setOff = nil
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        draw()
    }

    /// The glide as it is, fitted to its last frames (UIKit's slows by the deceleration rate every millisecond): where it
    /// is at its last frame, and how fast it goes there; where it would come to rest.
    private func fit(_ scrollView: UIScrollView) -> (y: Double, speed: Double, k: Double, t0: CFTimeInterval,
                                                      rest: Double)? {
        guard samples.count >= 3, let last = samples.last else { return nil }
        let k = 1000 * log(Double(scrollView.decelerationRate.rawValue))
        let n = Double(samples.count)
        var sumE = 0.0, sumY = 0.0, sumEE = 0.0, sumEY = 0.0
        for sample in samples {
            let e = exp(k * (sample.time - last.time))
            sumE += e
            sumY += sample.y
            sumEE += e * e
            sumEY += e * sample.y
        }
        let denominator = n * sumEE - sumE * sumE
        guard abs(denominator) > 1e-12 else { return nil }
        let b = (n * sumEY - sumE * sumY) / denominator
        let a = (sumY - b * sumE) / n
        return (a + b, b * k, k, last.time, a)
    }

    /// The rest of the glide, to where it comes to rest, on the render server.
    private func draw() {
        guard let scrollView, let curve else { return }
        let now = CACurrentMediaTime()
        let duration = curve.stop - now
        guard duration > 0 else { return }
        let steps = max(Int((duration * 120).rounded()), 1)
        let values = (0...steps).map { CGFloat(curve.position(at: now + duration * Double($0) / Double(steps))) }
        let animation = CAKeyframeAnimation(keyPath: "bounds.origin.y")
        animation.values = values
        animation.duration = duration
        animation.beginTime = scrollView.layer.convertTime(now, from: nil)
        animation.isRemovedOnCompletion = true
        scrollView.layer.add(animation, forKey: Self.key)
        // On its way to the render server now, where it can arrive before the hold it is for.
        CATransaction.flush()
        WallLog.note(String(format: "carry glide: %.1f now, at rest at %.1f in %.2f s%@", Double(values.first ?? 0),
                            curve.rest, duration, curve.edge == nil ? "" : " (edge)"))
    }

    @objc private func step() {
        guard let scrollView, let curve else { return drop() }
        let now = CACurrentMediaTime()
        moving = true
        defer { moving = false }
        if now >= curve.stop {
            scrollView.contentOffset.y = CGFloat(curve.rest)
            return drop()
        }
        scrollView.contentOffset.y = CGFloat(curve.position(at: now))
    }

    /// Whether a glide is taken over and still going.
    var isCarrying: Bool { curve != nil }

    /// Lets go of the glide: it has come to rest, or a finger came down on the scroll view.
    func drop() {
        link?.invalidate()
        link = nil
        curve = nil
        samples.removeAll()
        setOff = nil
        scrollView?.layer.removeAnimation(forKey: Self.key)
    }
}

/// Tells a scroll view's `GlideCarrier` how fast UIKit's glide sets off as a finger lets go, changing nothing. (Asked
/// again on every frame of the glide, by the look of it, with the same speed.)
struct GlideTargetReader: ScrollTargetBehavior {
    let carrier: () -> GlideCarrier?

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let speed = context.velocity.dy
        MainActor.assumeIsolated { carrier()?.noteSetOff(speed: speed) }
    }
}

#if DEBUG
/// `-stallKeyboardHide <ms>`: holds the main thread just after a finger lets go of a scroll view as the keyboard goes
/// down, as long as the keyboard's putting away holds it on the phone (~40 ms), to watch `carryRelease` in the
/// simulator; `-noReleaseCarry YES` leaves the motion to UIKit, to see the difference.
enum KeyboardHold {
    static func afterRelease() {
        let ms = UserDefaults.standard.double(forKey: "stallKeyboardHide")
        guard ms > 0 else { return }
        DispatchQueue.main.async { usleep(useconds_t(ms * 1000)) }
    }

    static var carries: Bool { !UserDefaults.standard.bool(forKey: "noReleaseCarry") }
}
#endif
