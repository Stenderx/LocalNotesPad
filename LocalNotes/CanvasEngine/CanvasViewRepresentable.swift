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
        context.coordinator.lastKnownDrawingData = drawing.dataRepresentation()
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.lastTool = activeTool
        apply(tool: activeTool, to: view)
        view.onDrawingMutatedBySnap = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.notify(drawing: view.drawing)
        }
        view.resetCanvasContentSize()
        return view
    }

    /// Applies SwiftUI state changes to the canvas without echoing them back as user edits.
    func updateUIView(_ uiView: InfiniteCanvasView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged

        if context.coordinator.lastTool != activeTool {
            apply(tool: activeTool, to: uiView)
            context.coordinator.lastTool = activeTool
        }

        let incoming = drawing.dataRepresentation()
        if incoming != context.coordinator.lastKnownDrawingData {
            context.coordinator.isPropagatingFromCanvas = true
            uiView.drawing = drawing
            context.coordinator.lastKnownDrawingData = incoming
            context.coordinator.isPropagatingFromCanvas = false
        }
    }

    /// Maps an `ActiveTool` onto the PencilKit tool installed on the canvas.
    @MainActor
    private func apply(tool: ActiveTool, to view: PKCanvasView) {
        switch tool {
        case .pen:
            view.tool = PKInkingTool(.pen, color: UIColor.label, width: 2.5)
        case .eraser:
            view.tool = PKEraserTool(.vector)
        }
    }

    /// Delegate bridge that also suppresses the echo of our own programmatic updates.
    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        /// Serialized form of the drawing the bridge last observed or pushed, used to detect real external changes.
        var lastKnownDrawingData: Data?
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
            }
            notify(drawing: canvasView.drawing)
        }

        /// Publishes a drawing produced inside the canvas (user edit or snap mutation).
        ///
        /// The `drawing` binding is deliberately not written back from here: doing so would feed
        /// SwiftUI state back into `updateUIView` on every stroke, replacing the live `PKDrawing`
        /// mid-gesture and breaking in-progress input. Instead the serialized snapshot is recorded
        /// in `lastKnownDrawingData` and the value is handed to the owner through
        /// `onDrawingChanged`, keeping the binding a strictly one-way programmatic input.
        func notify(drawing: PKDrawing) {
            lastKnownDrawingData = drawing.dataRepresentation()
            onDrawingChanged?(drawing)
        }
    }
}
