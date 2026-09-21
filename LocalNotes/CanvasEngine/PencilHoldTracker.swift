import UIKit

/// Intercepts Apple-Pencil touches on top of PencilKit's own recognisers and reports a
/// "draw & hold" gesture: the pencil stayed within `maximumMovement` for `holdDuration`
/// without lifting, which the canvas uses to snap the in-progress stroke to a straight line.
///
/// - Note: This recogniser never transitions to `.recognized`. It observes pencil touches
///   without cancelling or delaying them, and always returns `false` from `canPrevent(_:)`
///   and `canBePrevented(by:)`, so PencilKit's own recognisers continue to recognise
///   strokes simultaneously. The polling timer is always invalidated via `reset()`,
///   `touchesEnded(_:with:)` and `touchesCancelled(_:with:)`, so no `deinit` cleanup is
///   required.
@MainActor
final class PencilHoldTracker: UIGestureRecognizer {
    /// Time the pencil must stay (almost) still before the hold fires.
    var holdDuration: TimeInterval = 0.75

    /// Maximum drift allowed during the hold window, in points (view space).
    var maximumMovement: CGFloat = 4.0

    /// Strokes shorter than this are taps/dots and never fire the hold.
    var minimumStrokeLength: CGFloat = 8.0

    /// Called once when a pencil touch begins (used to warm up haptics).
    var onTouchBegan: (() -> Void)?

    /// Called exactly once per pencil touch sequence when the hold is detected.
    /// The location is expressed in the recogniser's view coordinate space.
    var onHoldDetected: ((CGPoint) -> Void)?

    /// Called when the pencil touch ends or is cancelled.
    var onTouchEnded: (() -> Void)?

    /// `true` once the hold has been reported for the current touch sequence.
    private var hasFired = false

    /// Location of the initial touch down, in view coordinates.
    private var touchDownLocation: CGPoint = .zero

    /// Reference point from which drift is measured during a hold candidate window.
    private var holdAnchorLocation: CGPoint = .zero

    /// Most recent sample that moved more than one point, in view coordinates.
    private var lastSampleLocation: CGPoint = .zero

    /// Timestamp of the most recent meaningful movement, from `CACurrentMediaTime()`.
    private var lastMovementTime: CFTimeInterval = 0

    /// Polling timer that evaluates the hold condition. Always invalidated through
    /// `stopPolling()`, which is reached from `reset()` and the touch-end callbacks,
    /// so no `deinit` cleanup is needed.
    private var pollTimer: Timer?

    /// Creates the recogniser and applies the pencil-only configuration.
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        configure()
    }

    /// Creates the recogniser from an archive and applies the pencil-only configuration.
    ///
    /// `UIGestureRecognizer.init(coder:)` is a convenience initializer, so a designated
    /// subclass initializer cannot chain to it; this required convenience initializer
    /// instead delegates to the designated `init(target:action:)`, which applies `configure()`.
    required convenience init?(coder: NSCoder) {
        self.init(target: nil, action: nil)
    }

    /// Restricts the recogniser to pencil touches while also supporting direct touches, without interfering with PencilKit.
    private func configure() {
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        requiresExclusiveTouchType = false
        cancelsTouchesInView = false
        delaysTouchesBegan = false
    }

    /// Always returns `false` so other recognisers, including PencilKit's, are not prevented.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    /// Always returns `false` so this recogniser is never prevented by another recogniser.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    /// Starts a touch sequence: records the origin, arms the hold and begins polling.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let event { super.touchesBegan(touches, with: event) }
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        let location = touch.location(in: view)
        touchDownLocation = location
        lastSampleLocation = location
        holdAnchorLocation = location
        hasFired = false
        lastMovementTime = CACurrentMediaTime()
        startPolling()
        onTouchBegan?()
    }

    /// Resets the hold window whenever the pencil drifts beyond `maximumMovement`.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let event { super.touchesMoved(touches, with: event) }
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        let location = touch.location(in: view)
        lastSampleLocation = location
        let drift = hypot(location.x - holdAnchorLocation.x, location.y - holdAnchorLocation.y)
        if drift > maximumMovement {
            holdAnchorLocation = location
            lastMovementTime = CACurrentMediaTime()
        }
    }

    /// Ends the touch sequence, invalidating the timer and rearming the hold.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let event { super.touchesEnded(touches, with: event) }
        stopPolling()
        hasFired = false
        state = .failed
        onTouchEnded?()
    }

    /// Cancels the touch sequence, invalidating the timer and rearming the hold.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let event { super.touchesCancelled(touches, with: event) }
        stopPolling()
        hasFired = false
        state = .cancelled
        onTouchEnded?()
    }

    /// Invalidates the polling timer and clears the hold state.
    override func reset() {
        super.reset()
        stopPolling()
        hasFired = false
        holdAnchorLocation = .zero
    }

    /// Restarts the polling timer on the main run loop in the common modes.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateHold()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Invalidates and releases the polling timer.
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Fires `onHoldDetected` once the pencil has been still long enough, remained within
    /// `maximumMovement` of the hold anchor, and moved far enough from touch down to count
    /// as a stroke rather than a tap.
    private func evaluateHold() {
        guard !hasFired else { return }
        guard CACurrentMediaTime() - lastMovementTime >= holdDuration else { return }
        guard hypot(lastSampleLocation.x - touchDownLocation.x,
                    lastSampleLocation.y - touchDownLocation.y) >= minimumStrokeLength else { return }
        guard hypot(lastSampleLocation.x - holdAnchorLocation.x,
                    lastSampleLocation.y - holdAnchorLocation.y) <= maximumMovement else { return }
        hasFired = true
        stopPolling()
        onHoldDetected?(lastSampleLocation)
    }
}
