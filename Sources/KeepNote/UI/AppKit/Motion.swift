import AppKit

/// Spring motion for windows and views, built on `SpringValue`.
///
/// Core Animation can spring a layer, but not an `NSWindow` frame, and the
/// deck, the peek and the note all move windows or re-lay-out views as they go.
/// So one shared timer steps every active spring instead. What this buys over
/// `NSAnimationContext` timing curves is that an animation can be *interrupted*:
/// aiming a moving spring at a new target keeps its velocity, so a tab that is
/// still lifting when the cursor leaves eases back rather than snapping.
enum Motion {
    /// System "Reduce Motion". Read at the moment an animation starts, so
    /// flipping it in System Settings applies without a restart.
    static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Lets `Scripts/render.sh` exercise both modes; nil in the app.
    static var reduceMotionOverride: Bool?
}

/// Drives all running springs from one timer, and stops it when none run.
@MainActor
private final class SpringTicker {
    static let shared = SpringTicker()

    private var animators: [ObjectIdentifier: SpringAnimator] = [:]
    private var timer: Timer?
    private var last: CFTimeInterval = 0

    func start(_ animator: SpringAnimator) {
        animators[ObjectIdentifier(animator)] = animator
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(_ animator: SpringAnimator) {
        animators.removeValue(forKey: ObjectIdentifier(animator))
        if animators.isEmpty { cancelTimer() }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - last
        last = now
        for animator in Array(animators.values) {
            animator.tick(now: now, dt: dt)
        }
        if animators.isEmpty { cancelTimer() }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// A group of numbers springing together toward targets — a frame and an
/// opacity, say. `onUpdate` is called with the current values every step.
@MainActor
final class SpringAnimator {
    private(set) var springs: [SpringValue]
    private var targets: [Double]
    private var configs: [SpringConfig]
    private let precisions: [Double]
    private var startsAt: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var running = false

    var onUpdate: (([Double]) -> Void)?

    var values: [Double] { springs.map(\.value) }
    var isAnimating: Bool { running }

    /// `precisions` is how close each channel must be to count as arrived;
    /// points for geometry, a few thousandths for opacity.
    init(values: [Double], precisions: [Double]? = nil) {
        springs = values.map { SpringValue(value: $0) }
        targets = values
        configs = Array(repeating: .note, count: values.count)
        self.precisions = precisions ?? Array(repeating: 0.25, count: values.count)
    }

    /// Aims every channel at `targets`. A previous animation is not finished
    /// off, it is bent toward the new goal, and its completion never runs.
    ///
    /// With Reduce Motion on, channels in `fading` still animate — as a short
    /// fade — and the rest jump straight to their targets.
    func animate(
        to newTargets: [Double],
        config: SpringConfig,
        delay: TimeInterval = 0,
        fading: Set<Int> = [],
        completion: (() -> Void)? = nil
    ) {
        precondition(newTargets.count == springs.count)
        self.completion = completion
        targets = newTargets
        let reduced = Motion.reduceMotion
        for index in springs.indices {
            if reduced && !fading.contains(index) {
                springs[index] = SpringValue(value: newTargets[index])
                configs[index] = config
            } else {
                configs[index] = reduced ? .fade : config
            }
        }
        startsAt = CACurrentMediaTime() + (reduced ? 0 : delay)
        if reduced { onUpdate?(values) }
        running = true
        SpringTicker.shared.start(self)
    }

    /// Stops and sets the values, no motion.
    func jump(to newValues: [Double]) {
        precondition(newValues.count == springs.count)
        halt()
        springs = newValues.map { SpringValue(value: $0) }
        targets = newValues
        onUpdate?(values)
    }

    /// Stops where it is.
    func stop() {
        halt()
        completion = nil
    }

    private func halt() {
        running = false
        SpringTicker.shared.stop(self)
    }

    fileprivate func tick(now: CFTimeInterval, dt: Double) {
        guard running, now >= startsAt else { return }
        for index in springs.indices {
            springs[index].advance(by: dt, toward: targets[index], config: configs[index])
        }
        let settled = springs.indices.allSatisfy {
            springs[$0].isSettled(at: targets[$0], precision: precisions[$0])
        }
        if settled {
            for index in springs.indices { springs[index] = SpringValue(value: targets[index]) }
        }
        onUpdate?(values)
        if settled {
            halt()
            let done = completion
            completion = nil
            done?()
        }
    }
}

// MARK: - Windows

/// A window's frame and opacity on springs.
@MainActor
final class WindowMotion {
    private weak var window: NSWindow?
    private let animator: SpringAnimator

    /// Called on every step after the frame has been applied.
    var onStep: (() -> Void)?

    init(window: NSWindow) {
        self.window = window
        let frame = window.frame
        animator = SpringAnimator(
            values: [frame.minX, frame.minY, frame.width, frame.height, Double(window.alphaValue)],
            precisions: [0.25, 0.25, 0.25, 0.25, 0.004]
        )
        animator.onUpdate = { [weak self] values in self?.apply(values) }
    }

    var isAnimating: Bool { animator.isAnimating }

    /// Sets the frame and opacity at once, cancelling any motion.
    func place(frame: NSRect, alpha: CGFloat) {
        animator.jump(to: Self.values(frame, alpha))
    }

    func move(to frame: NSRect, alpha: CGFloat, config: SpringConfig, completion: (() -> Void)? = nil) {
        // Start from where the window really is, in case it was moved by hand.
        syncFromWindow()
        animator.animate(to: Self.values(frame, alpha), config: config, fading: [4], completion: completion)
    }

    func stop() { animator.stop() }

    private func syncFromWindow() {
        guard let window, !animator.isAnimating else { return }
        let frame = window.frame
        animator.jump(to: Self.values(frame, window.alphaValue))
    }

    private static func values(_ frame: NSRect, _ alpha: CGFloat) -> [Double] {
        [frame.minX, frame.minY, frame.width, frame.height, Double(alpha)]
    }

    private func apply(_ values: [Double]) {
        guard let window else { return }
        // A spring may overshoot; a window may not go smaller than nothing.
        let frame = NSRect(x: values[0], y: values[1], width: max(1, values[2]), height: max(1, values[3]))
        if window.frame != frame { window.setFrame(frame, display: true) }
        window.alphaValue = CGFloat(min(1, max(0, values[4])))
        onStep?()
    }
}

// MARK: - Views

/// A view that springs between frames and opacities. The deck's tabs, the
/// "+" and the "+N" chip are all this.
@MainActor
class SpringView: NSView {
    private lazy var motion: SpringAnimator = {
        let animator = SpringAnimator(
            values: [frame.minX, frame.minY, frame.width, frame.height, Double(alphaValue)],
            precisions: [0.25, 0.25, 0.25, 0.25, 0.004]
        )
        animator.onUpdate = { [weak self] values in
            guard let self else { return }
            self.setFrameSizeAndOrigin(NSRect(x: values[0], y: values[1], width: max(1, values[2]), height: max(1, values[3])))
            self.alphaValue = CGFloat(min(1, max(0, values[4])))
        }
        return animator
    }()

    /// The frame this view is heading for (its current one when at rest).
    private(set) var targetFrame: NSRect = .zero
    private(set) var targetAlpha: CGFloat = 1

    private func setFrameSizeAndOrigin(_ rect: NSRect) {
        if frame != rect { frame = rect }
    }

    /// Sets frame and opacity immediately.
    func place(frame rect: NSRect, alpha: CGFloat? = nil) {
        targetFrame = rect
        if let alpha { targetAlpha = alpha }
        motion.jump(to: [rect.minX, rect.minY, rect.width, rect.height, Double(targetAlpha)])
    }

    /// Springs to a frame (and optionally an opacity); aimed again mid-flight,
    /// it keeps its velocity.
    func move(to rect: NSRect, alpha: CGFloat? = nil, config: SpringConfig, delay: TimeInterval = 0) {
        targetFrame = rect
        if let alpha { targetAlpha = alpha }
        if !motion.isAnimating { motion.jump(to: [frame.minX, frame.minY, frame.width, frame.height, Double(alphaValue)]) }
        motion.animate(
            to: [rect.minX, rect.minY, rect.width, rect.height, Double(targetAlpha)],
            config: config,
            delay: delay,
            fading: [4]
        )
    }

    func stopMotion() { motion.stop() }
}
