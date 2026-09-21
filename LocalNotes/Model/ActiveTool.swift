import Foundation

/// The drawing tool selected in the minimalist floating toolbar.
enum ActiveTool: String, CaseIterable, Identifiable, Sendable {
    /// Freehand pen; new ink is drawn with the current pen settings.
    case pen
    /// Vector eraser; whole strokes are removed instead of pixels.
    case eraser

    /// Stable identity used by SwiftUI diffing.
    var id: String { rawValue }
    /// SF Symbol name used by the toolbar.
    var symbolName: String { self == .pen ? "pencil.tip" : "eraser" }
    /// Accessibility label for the toolbar button.
    var accessibilityLabel: String { self == .pen ? "Pen" : "Vector eraser" }
}
