import UIKit
import PencilKit

/// A `PKCanvasView` (itself a `UIScrollView`) that never runs out of vertical room:
/// the content height grows on demand, the squared-paper grid scrolls with the ink, and
/// the Apple Pencil has priority while fingers stay reserved for panning and zooming.
@MainActor
final class InfiniteCanvasView: PKCanvasView {

    /// Recogniser that detects the "draw and hold" gesture performed with the pencil.
    let holdTracker: PencilHoldTracker

    /// Spacing, in points, of the squared-paper grid drawn behind the ink.
    var gridSpacing: CGFloat = CanvasGridPattern.defaultSpacing

    /// Distance from the bottom of the content, in points, at which the canvas grows again during active scrolling.
    var extensionThreshold: CGFloat = 600

    /// Number of points added to the content height each time the canvas grows.
    var extensionAmount: CGFloat = 2000

    /// Delay of user inactivity before trimming excess empty canvas space at the bottom (seconds).
    var idleTrimDelay: TimeInterval = 2.0

    /// Minimum excess height (in points) above the needed content required to trigger a trim.
    var excessTrimThreshold: CGFloat = 400

    /// Timer scheduled to evaluate and trim excess bottom space when the canvas is idle.
    private var idleTrimTimer: Timer?

    /// Called whenever the drawing was rewritten by a snap operation.
    var onDrawingMutatedBySnap: (() -> Void)?

    /// Called after a successful snap so the host can play its own feedback.
    var onSnapFeedback: (() -> Void)?

    /// `true` while a straightened stroke is staged and waiting for the touch to end.
    var hasPendingSnap: Bool { pendingSnap != nil }

    /// Grid backdrop painted behind PencilKit's transparent drawing surface.
    private let gridView = UIView()

    /// Light impact generator that confirms a successful snap.
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Re-entrancy guard for `extendCanvasIfNeeded()`.
    private var isExtending = false

    /// Re-entrancy guard for `trimExcessCanvasIfNeeded()`.
    private var isTrimming = false

    /// Re-entrancy guard for `reapplyPendingSnapIfNeeded()`.
    private var isReapplyingSnap = false

    /// Straightened stroke staged by a snap, together with its index in `drawing.strokes`.
    private var pendingSnap: (index: Int, stroke: PKStroke)?

    /// Observation of `contentOffset` that grows the canvas while scrolling towards the bottom.
    private var offsetObservation: NSKeyValueObservation?

    /// Observation of `zoomScale` that keeps the grid geometry in sync while pinching.
    private var zoomObservation: NSKeyValueObservation?

    /// Creates a canvas with the shared configuration.
    override init(frame: CGRect) {
        holdTracker = PencilHoldTracker()
        super.init(frame: frame)
        configureCanvas()
    }

    /// Creates a canvas from a storyboard or an archive.
    required init?(coder: NSCoder) {
        holdTracker = PencilHoldTracker()
        super.init(coder: coder)
        configureCanvas()
    }

    /// Applies the configuration shared by both initialisers, installs the grid backdrop
    /// and registers the draw-and-hold recogniser.
    ///
    /// - Note: Opacity must stay off so the grid view behind PencilKit's transparent drawing
    ///   surface shows through; the canvas itself must not carry the pattern, because a
    ///   viewport-anchored background would stay glued to the screen instead of scrolling
    ///   with the ink. `gridView` lives in the canvas' content space and follows the ink.
    private func configureCanvas() {
        #if targetEnvironment(simulator)
        drawingPolicy = .anyInput
        #else
        drawingPolicy = .default
        #endif
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = false
        minimumZoomScale = 0.5
        maximumZoomScale = 4.0
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        isOpaque = false

        gridView.isUserInteractionEnabled = false
        gridView.isOpaque = true
        gridView.autoresizingMask = []
        gridView.backgroundColor = CanvasGridPattern.makeGridColor(
            spacing: gridSpacing,
            traitCollection: traitCollection
        )
        insertSubview(gridView, at: 0)

        holdTracker.holdDuration = 0.75
        holdTracker.maximumMovement = 4.0
        addGestureRecognizer(holdTracker)

        registerGridTraitObserver()

        holdTracker.onTouchBegan = { [weak self] in
            self?.haptic.prepare()
        }
        holdTracker.onHoldDetected = { [weak self] _ in
            guard let self, self.snapLastStrokeToStraightLine() else { return }
            self.haptic.impactOccurred(intensity: 0.8)
            self.onSnapFeedback?()
        }
        holdTracker.onTouchEnded = { [weak self] in
            self?.finalizePendingSnap()
            self?.scheduleIdleTrim()
        }
    }

    /// Keeps the grid pinned to the content origin, syncs width with the viewport,
    /// and grows the canvas when actively scrolling near the bottom edge.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        var geometryChanged = false

        if contentSize.width != bounds.width {
            contentSize.width = bounds.width
            geometryChanged = true
        }

        let minHeight = max(bounds.height, 2000)
        let drawingBottom = drawing.bounds.maxY
        let requiredHeight = max(minHeight, drawingBottom + 800)
        if contentSize.height < minHeight {
            contentSize.height = requiredHeight
            geometryChanged = true
        }

        if geometryChanged {
            updateGridPattern()
            updateGridFrame()
        }

        sendSubviewToBack(gridView)
        updateGridFrame()
        extendCanvasIfNeeded()
    }

    /// Starts observing the scroll offset and the zoom scale the first time the canvas
    /// enters a window, so the observations are created exactly once.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard offsetObservation == nil else { return }

        offsetObservation = observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.extendCanvasIfNeeded()
                self?.scheduleIdleTrim()
            }
        }
        zoomObservation = observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateGridPattern()
                self?.updateGridFrame()
                self?.extendCanvasIfNeeded()
            }
        }
    }

    /// Re-resolves the grid tile pattern for the current zoom scale and display traits so
    /// squared-paper tiles zoom together with the ink while staying sharp.
    func updateGridPattern() {
        let currentScale = zoomScale > 0 ? zoomScale : 1.0
        let effectiveSpacing = gridSpacing * currentScale
        gridView.backgroundColor = CanvasGridPattern.makeGridColor(
            spacing: effectiveSpacing,
            traitCollection: traitCollection
        )
    }

    /// Refreshes the grid colour when the traits that affect the rendered tile change.
    ///
    /// - Note: Registers with the iOS 17 `UITraitChangeObservable` API instead of the
    ///   deprecated `traitCollectionDidChange(_:)`, so the backdrop stays in step with
    ///   dynamic colours, contrast, active appearance and display scale.
    private func registerGridTraitObserver() {
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
            UITraitActiveAppearance.self,
            UITraitDisplayScale.self,
        ]) { (view: InfiniteCanvasView, _: UITraitCollection) in
            view.updateGridPattern()
        }
    }

    /// Grows the content height by `extensionAmount` when the user is actively scrolling towards the bottom edge,
    /// or when the content is shorter than the viewport. The width is never touched and the content never shrinks.
    func extendCanvasIfNeeded() {
        guard bounds.height > 0 else { return }
        guard !isExtending, !isTrimming else { return }

        let isShorterThanViewport = contentSize.height < bounds.height
        let isActivelyScrolling = isTracking || isDragging || isDecelerating
        let isNearBottom = contentOffset.y + bounds.height > contentSize.height - extensionThreshold

        guard isShorterThanViewport || (isActivelyScrolling && isNearBottom) else { return }

        isExtending = true
        contentSize.height = max(contentSize.height, bounds.height) + extensionAmount
        updateGridFrame()
        isExtending = false
    }

    /// Restores the content size to the current viewport or drawing bounds, at least 2000 points tall.
    func resetCanvasContentSize(for drawing: PKDrawing? = nil) {
        let width = bounds.width > 0 ? bounds.width : 0
        let minHeight = bounds.height > 0 ? max(bounds.height, 2000) : 2000
        let drawingBottom = drawing?.bounds.maxY ?? 0
        let targetHeight = max(minHeight, drawingBottom + 800)
        contentSize = CGSize(width: width, height: targetHeight)
        updateGridPattern()
        updateGridFrame()
    }

    /// Resets the viewport offset and zoom scale back to default origin (0, 0) and 1.0x zoom.
    func resetViewport() {
        setContentOffset(.zero, animated: false)
        setZoomScale(1.0, animated: false)
        updateGridPattern()
        updateGridFrame()
    }

    /// Straightens the most recent stroke of `drawing` when the active tool is an inking tool.
    ///
    /// The straightened stroke is staged in `pendingSnap` because PencilKit keeps writing to
    /// the original stroke while the pencil is still down; the staged copy is re-applied by
    /// `reapplyPendingSnapIfNeeded()` and committed by `finalizePendingSnap()`.
    ///
    /// - Returns: `true` when a stroke was snapped, `false` otherwise.
    @discardableResult
    func snapLastStrokeToStraightLine() -> Bool {
        guard tool is PKInkingTool else { return false }
        guard let result = StraightLineSnapper.straightenedLastStroke(in: drawing) else { return false }

        pendingSnap = (result.strokeIndex, result.stroke)
        drawing = result.drawing
        onDrawingMutatedBySnap?()
        return true
    }

    /// Re-applies the staged stroke when PencilKit has replaced it with the original
    /// freehand version, keeping the straightened geometry while the pencil stays down.
    func reapplyPendingSnapIfNeeded() {
        guard let pending = pendingSnap,
              !isReapplyingSnap,
              pending.index < drawing.strokes.count,
              drawing.strokes[pending.index].path.count != pending.stroke.path.count
        else { return }

        isReapplyingSnap = true
        defer { isReapplyingSnap = false }

        var strokes = drawing.strokes
        strokes[pending.index] = pending.stroke
        drawing = PKDrawing(strokes: strokes)
    }

    /// Commits the staged stroke when the pencil lifts, then clears the pending snap and
    /// notifies the host that the drawing changed.
    private func finalizePendingSnap() {
        guard let pending = pendingSnap else { return }

        if pending.index < drawing.strokes.count {
            var strokes = drawing.strokes
            strokes[pending.index] = pending.stroke
            drawing = PKDrawing(strokes: strokes)
        }

        pendingSnap = nil
        onDrawingMutatedBySnap?()
        scheduleIdleTrim()
    }

    /// Schedules an idle evaluation to trim large unused empty space at the bottom of the canvas.
    func scheduleIdleTrim() {
        idleTrimTimer?.invalidate()
        let timer = Timer(timeInterval: idleTrimDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trimExcessCanvasIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTrimTimer = timer
    }

    /// Trims excess empty space at the bottom of the canvas if the user has left a large unused tail.
    ///
    /// The trimmed height always preserves:
    /// 1. All drawn ink strokes (`drawing.bounds.maxY`).
    /// 2. The baseline note height (at least 2000 pt and viewport height).
    /// 3. A comfortable breathing room buffer of 800 pt below the lowest ink stroke.
    ///
    /// If the viewport was left sitting in the empty tail, it is smoothly animated back to
    /// the end of the content before trimming. Subsequent downward scrolling will seamlessly
    /// extend the canvas again.
    func trimExcessCanvasIfNeeded() {
        // Do not trim while the user is actively touching, dragging, decelerating, or during extension/trimming
        guard !isTracking, !isDragging, !isDecelerating, !isExtending, !isTrimming else {
            scheduleIdleTrim()
            return
        }
        guard bounds.height > 0 else { return }

        let minHeight = max(bounds.height, 2000)
        let drawingBottom = drawing.bounds.maxY
        let buffer: CGFloat = 800
        let neededHeight = max(minHeight, drawingBottom + buffer)

        // Only trim if there is noticeable excess space beyond the needed content
        guard contentSize.height > neededHeight + excessTrimThreshold else { return }

        let maxOffsetY = max(0, neededHeight - bounds.height)

        if contentOffset.y > maxOffsetY {
            // Viewport is currently sitting down in the empty space that will be trimmed.
            // Animate it smoothly back up to the end of the content, then trim contentSize.
            isTrimming = true
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.contentOffset = CGPoint(x: self.contentOffset.x, y: maxOffsetY)
            } completion: { [weak self] finished in
                guard let self else { return }
                self.isTrimming = false
                if finished && !self.isTracking && !self.isDragging {
                    self.contentSize.height = neededHeight
                    self.updateGridFrame()
                }
            }
        } else {
            // Viewport is already above the trimmed region. Trim directly.
            contentSize.height = neededHeight
            updateGridFrame()
        }
    }

    /// Sizes the grid view so it covers the whole scrollable content.
    private func updateGridFrame() {
        gridView.frame = CGRect(origin: .zero, size: contentSize)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            idleTrimTimer?.invalidate()
            idleTrimTimer = nil
        }
    }
}
