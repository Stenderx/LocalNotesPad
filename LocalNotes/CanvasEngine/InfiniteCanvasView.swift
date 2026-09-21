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

    /// Distance from the bottom of the content, in points, at which the canvas grows again.
    var extensionThreshold: CGFloat = 1200

    /// Number of points added to the content height each time the canvas grows.
    var extensionAmount: CGFloat = 3000

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
        drawingPolicy = .pencilOnly
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
        }
    }

    /// Keeps the grid pinned to the content origin and grows the canvas when the visible
    /// area approaches the bottom edge.
    override func layoutSubviews() {
        super.layoutSubviews()
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
            }
        }
        zoomObservation = observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateGridFrame()
                self?.extendCanvasIfNeeded()
            }
        }
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
            view.gridView.backgroundColor = CanvasGridPattern.makeGridColor(
                spacing: view.gridSpacing,
                traitCollection: view.traitCollection
            )
        }
    }

    /// Grows the content height by `extensionAmount` once the visible area gets within
    /// `extensionThreshold` points of the bottom edge, or when the content is shorter than
    /// the viewport. The width is never touched and the content never shrinks.
    func extendCanvasIfNeeded() {
        guard bounds.height > 0 else { return }
        guard !isExtending else { return }

        let isNearBottom = contentOffset.y + bounds.height > contentSize.height - extensionThreshold
        let isShorterThanViewport = contentSize.height < bounds.height
        guard isNearBottom || isShorterThanViewport else { return }

        isExtending = true
        contentSize.height = max(contentSize.height, bounds.height) + extensionAmount
        updateGridFrame()
        isExtending = false
    }

    /// Restores the content size to the current viewport, at least 2000 points tall.
    func resetCanvasContentSize() {
        guard bounds.width > 0 else { return }
        contentSize = CGSize(width: bounds.width, height: max(bounds.height, 2000))
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
    }

    /// Sizes the grid view so it covers the whole scrollable content.
    private func updateGridFrame() {
        gridView.frame = CGRect(origin: .zero, size: contentSize)
    }
}
