import Foundation

/// The drawing tool selected in the minimalist floating toolbar.
enum ActiveTool: String, CaseIterable, Identifiable, Sendable {
    /// Freehand pen; new ink is drawn with the current pen settings.
    case pen
    /// Vector eraser; whole strokes are removed instead of pixels.
    case eraser
    /// Pan and scroll tool; drags scroll the canvas without producing ink marks.
    case pan

    /// Stable identity used by SwiftUI diffing.
    var id: String { rawValue }
    /// SF Symbol name used by the toolbar.
    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .pan: return "hand.draw"
        }
    }
    /// Accessibility label for the toolbar button.
    var accessibilityLabel: String {
        switch self {
        case .pen: return "Pen"
        case .eraser: return "Vector eraser"
        case .pan: return "Pan and scroll"
        }
    }
}
