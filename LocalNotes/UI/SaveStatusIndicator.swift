import SwiftUI

/// Compact, non-invasive autosave status used inside `FloatingToolbar`.
///
/// Renders one of four visual states driven by `NotesViewModel.SaveStatus`:
/// - `idle`: nothing is shown, but the row height is preserved.
/// - `saving`: a small spinner plus a "Saving…" label.
/// - `saved`: a checkmark plus a stable "Saved" label; the exact time is
///   exposed only through the help tooltip and accessibility value.
/// - `failed`: a warning triangle plus a "Not saved" label tinted orange;
///   the underlying error message is exposed through the help tooltip.
///
/// The view always occupies a fixed 22 pt height so surrounding toolbar
/// layout does not shift as the status changes.
struct SaveStatusIndicator: View {
    /// The autosave state reported by the active `NotesViewModel`.
    var status: NotesViewModel.SaveStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .saving:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…")
                }
                .accessibilityLabel("Saving")
            case .saved(let date):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Saved")
                }
                .help(date.formatted(date: .abbreviated, time: .shortened))
                .accessibilityValue(date.formatted(date: .abbreviated, time: .shortened))
                .accessibilityLabel("Saved")
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Not saved")
                }
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityValue(message)
                .accessibilityLabel("Not saved")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .frame(height: 22)
        .transition(.opacity)
        .animation(.default, value: status)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Save Status") {
    VStack(alignment: .leading, spacing: 12) {
        SaveStatusIndicator(status: .saving)
        SaveStatusIndicator(status: .saved(.now))
        SaveStatusIndicator(status: .failed("The document could not be written to disk."))
    }
    .padding()
}
