import SwiftUI
import PencilKit

/// Full-screen drawing surface for a single note, with a minimalist floating toolbar.
///
/// The canvas is the star: it fills every edge except the top navigation strip and is
/// topped only by the translucent ``FloatingToolbar``. Programmatic drawing changes flow
/// through ``draft``; user edits arrive through the canvas callback and are mirrored in
/// ``latestDrawing`` so a note switch, an export or the view disappearing can flush the
/// freshest strokes to ``NotesViewModel`` before the editing session ends.
///
/// The navigation bar stays available for iPadOS's navigation and back gestures, but its
/// background is hidden so the bar visually recedes behind the ink.
struct NoteDetailView: View {
    /// The observable source of truth shared with the note list and the canvas.
    @Bindable var viewModel: NotesViewModel

    /// The note currently being edited.
    let note: NoteDocument

    /// The drawing bound to the canvas for the current editing session.
    ///
    /// It is only written programmatically (when a note is loaded); user edits are reported
    /// through the canvas callback and stored in ``latestDrawing`` instead, keeping the
    /// binding a one-way input for the representable.
    @State private var draft = PKDrawing()

    /// The most recent drawing reported by the canvas, if the user edited it.
    @State private var latestDrawing: PKDrawing?

    /// The PDF awaiting presentation in the share sheet, if an export ran.
    @State private var exportedItem: ExportedItem?

    /// Identity of the note whose drawing is currently loaded into ``draft``.
    @State private var loadedNoteID: NoteDocument.ID?

    /// The previously edited note, resolved from the view model's selection history.
    ///
    /// The loading task needs the full outgoing note — not just its identifier — to flush
    /// its pending autosave before the canvas switches drawings. `NotesViewModel` exposes
    /// both ``NotesViewModel/lastActiveNoteID`` and ``NotesViewModel/notes``, so the note
    /// value is looked up on demand rather than duplicated in this view's state, keeping a
    /// single source of truth for what was loaded before.
    private var previousNote: NoteDocument? {
        guard let previousID = viewModel.lastActiveNoteID else { return nil }
        return viewModel.notes.first { $0.id == previousID }
    }

    var body: some View {
        ZStack(alignment: .top) {
            CanvasViewRepresentable(drawing: $draft, activeTool: viewModel.activeTool) { drawing in
                latestDrawing = drawing
                viewModel.scheduleSave(drawing: drawing, for: note)
            }
            .ignoresSafeArea(edges: [.horizontal, .bottom])

            FloatingToolbar(activeTool: $viewModel.activeTool, saveStatus: viewModel.saveStatus) {
                exportPDF()
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .safeAreaPadding(.top, 4)
        }
        .task(id: note.id) {
            if let previous = previousNote, loadedNoteID != note.id {
                flush(previous)
            }
            draft = viewModel.loadDrawing(for: note) ?? PKDrawing()
            latestDrawing = nil
            loadedNoteID = note.id
        }
        .onDisappear {
            flush(note)
        }
        .sheet(item: $exportedItem) { item in
            ShareSheet(items: [item.url])
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportPDF()
                } label: {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// Persists whatever the canvas currently holds for `note`.
    ///
    /// - Parameters:
    ///   - note: The note whose strokes should be written to disk.
    ///   - drawing: An explicit drawing to persist; when `nil`, the most recent canvas edit
    ///     (``latestDrawing``) is used, so a note that was never edited after loading simply
    ///     cancels its pending debounce instead of rewriting identical ink.
    private func flush(_ note: NoteDocument, drawing: PKDrawing? = nil) {
        viewModel.flushPendingSave(drawing: drawing ?? latestDrawing, for: note)
    }

    /// Flushes the freshest canvas content, then presents the exported PDF in the share sheet.
    ///
    /// The export must not race the debounced autosave: the drawing held here is saved first
    /// so the generated PDF matches exactly what the user sees. A new ``ExportedItem`` is
    /// only created when the view model successfully produced a file, which gives the sheet a
    /// fresh identity for every export.
    private func exportPDF() {
        viewModel.flushPendingSave(drawing: latestDrawing ?? draft, for: note)
        if let url = viewModel.exportPDF(for: note) {
            exportedItem = ExportedItem(url: url)
        }
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(
            viewModel: NotesViewModel(),
            note: NoteDocument(
                id: UUID(),
                title: "Preview",
                createdAt: .now,
                modifiedAt: .now,
                fileURL: URL(fileURLWithPath: "/dev/null"),
                fileSize: 0,
                strokeCount: 0
            )
        )
    }
}
