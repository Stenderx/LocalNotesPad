import SwiftUI
import PencilKit

/// SwiftUI bridge for `InfiniteCanvasView`.
///
/// `drawing` is a *one-way* input for programmatic changes (loading a note): user edits are
/// reported through `onDrawingChanged`, so SwiftUI state updates never loop back into
/// PencilKit while the user is drawing.
struct CanvasViewRepresentable: UIViewRepresentable {
    /// The drawing the canvas should display; programmatic writes (for example loading a note) flow through here.
    @Binding var drawing: PKDrawing
    /// The tool currently selected in the surrounding UI.
    var activeTool: ActiveTool
    /// Called after every user edit, including Draw & Hold snap mutations.
    var onDrawingChanged: (PKDrawing) -> Void

    /// Creates the delegate bridge that reconciles SwiftUI state with the canvas.
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Creates the canvas, seeds it with the bound drawing, and wires the snap-mutation callback.
    func makeUIView(context: Context) -> InfiniteCanvasView {
        let view = InfiniteCanvasView(frame: .zero)
        view.delegate = context.coordinator
        view.drawing = drawing
        let initialData = drawing.dataRepresentation()
        context.coordinator.lastExternalDrawingData = initialData
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.lastTool = activeTool
        apply(tool: activeTool, to: view)
        view.onDrawingMutatedBySnap = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.notify(drawing: view.drawing)
        }
        view.resetCanvasContentSize(for: drawing)
        view.resetViewport()
        return view
    }

    /// Applies SwiftUI state changes to the canvas without echoing them back as user edits.
    func updateUIView(_ uiView: InfiniteCanvasView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged

        if context.coordinator.lastTool != activeTool {
            apply(tool: activeTool, to: uiView)
            context.coordinator.lastTool = activeTool
        }

        // Only update the canvas drawing if external SwiftUI state actually changed (e.g. loading a different note).
        // NEVER overwrite the canvas drawing while the user is actively drawing strokes!
        let incomingData = drawing.dataRepresentation()
        if incomingData != context.coordinator.lastExternalDrawingData {
            context.coordinator.lastExternalDrawingData = incomingData
            context.coordinator.isPropagatingFromCanvas = true
            uiView.drawing = drawing
            uiView.resetCanvasContentSize(for: drawing)
            context.coordinator.isPropagatingFromCanvas = false
        }
    }

    /// Maps an `ActiveTool` onto the PencilKit tool installed on the canvas.
    @MainActor
    private func apply(tool: ActiveTool, to view: PKCanvasView) {
        switch tool {
        case .pen:
            #if targetEnvironment(simulator)
            view.drawingPolicy = .anyInput
            #else
            view.drawingPolicy = .default
            #endif
            view.tool = PKInkingTool(.pen, color: UIColor.label, width: 2.5)
        case .eraser:
            #if targetEnvironment(simulator)
            view.drawingPolicy = .anyInput
            #else
            view.drawingPolicy = .default
            #endif
            view.tool = PKEraserTool(.vector)
        case .pan:
            // In pan mode, touch inputs pan/scroll the scroll view instead of drawing marks
            view.drawingPolicy = .pencilOnly
        }
    }

    /// Delegate bridge that also suppresses the echo of our own programmatic updates.
    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        /// Serialized form of the drawing last observed or externally pushed.
        var lastExternalDrawingData: Data?
        /// The last tool applied to the canvas, so redundant tool reassignments are skipped.
        var lastTool: ActiveTool?
        /// Set while `updateUIView` is writing to the canvas, so the resulting delegate callback is ignored.
        var isPropagatingFromCanvas: Bool = false
        /// Callback forwarded to the representable's `onDrawingChanged`.
        var onDrawingChanged: ((PKDrawing) -> Void)?

        /// Reacts to drawing changes, first letting a pending Draw & Hold snap mutate the canvas.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isPropagatingFromCanvas else { return }
            if let canvas = canvasView as? InfiniteCanvasView {
                canvas.reapplyPendingSnapIfNeeded()
                canvas.scheduleIdleTrim()
            }
            notify(drawing: canvasView.drawing)
        }

        /// Publishes a drawing produced inside the canvas (user edit or snap mutation).
        func notify(drawing: PKDrawing) {
            lastExternalDrawingData = drawing.dataRepresentation()
            onDrawingChanged?(drawing)
        }
    }
}
