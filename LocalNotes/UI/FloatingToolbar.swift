import SwiftUI

/// Minimalist translucent bar floating over the canvas: pen / vector-eraser toggle,
/// autosave status and the PDF export action. Deliberately replaces the system `PKToolPicker`.
///
/// The bar sits above the canvas and must not swallow scroll gestures outside its buttons.
/// SwiftUI only routes events through the hit-testable button shapes, and the bar's own frame
/// is kept tight to its content (`HStack` sizing, no `Spacer()`, no full-width background),
/// so touches and drags that start outside the buttons fall through to the canvas below.
struct FloatingToolbar: View {
    /// Currently selected drawing tool, owned by the parent so the toolbar and canvas stay in sync.
    @Binding var activeTool: ActiveTool

    /// Autosave state rendered by `SaveStatusIndicator(status:)`.
    var saveStatus: NotesViewModel.SaveStatus

    /// Invoked when the user taps the PDF export button.
    var onExport: () -> Void

    /// Shape shared by the bar's material background and its hairline stroke overlay.
    private let barShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Shape used for the selected-tool highlight behind each tool button.
    private let buttonShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ActiveTool.allCases) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(height: 22)

            SaveStatusIndicator(status: saveStatus)
                .frame(minWidth: 92, alignment: .leading)

            Divider()
                .frame(height: 22)

            exportButton
        }
        .padding(6)
        .background(.regularMaterial, in: barShape)
        .overlay(barShape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .animation(.snappy(duration: 0.2), value: activeTool)
    }

    /// Tool toggle button: tinted symbol with a 44x44 hit target and a selected-state highlight.
    /// Tapping the active tool again is a no-op from the canvas' point of view.
    @ViewBuilder
    private func toolButton(_ tool: ActiveTool) -> some View {
        Button {
            activeTool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(activeTool == tool ? Color.accentColor : Color.primary)
        .background(
            buttonShape.fill(activeTool == tool ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .accessibilityLabel(Text(tool.accessibilityLabel))
        .accessibilityAddTraits(activeTool == tool ? [.isSelected] : [])
    }

    /// PDF export button sharing the tool buttons' 44x44 hit target and plain button style.
    private var exportButton: some View {
        Button {
            onExport()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityLabel(Text("Export PDF"))
    }
}

#Preview {
    FloatingToolbar(activeTool: .constant(.pen), saveStatus: .idle, onExport: {})
}
