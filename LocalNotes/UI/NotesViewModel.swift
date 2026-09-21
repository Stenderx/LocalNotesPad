import Foundation
import Observation
import PencilKit

/// Single source of truth for the note list, the current selection, the active tool and autosave.
///
/// The `@Observable` macro and the `didSet` observer on ``selectedNoteID`` coexist
/// without conflict: the macro generates the observation accessors while the
/// observer still runs on every assignment, so change tracking and the
/// "remember the previously selected note" side effect both keep working.
/// Every mutation happens on the main actor because the whole class is
/// isolated with `@MainActor` and the autosave `Task` inherits that isolation.
@MainActor
@Observable
final class NotesViewModel {
    /// Non-invasive autosave status rendered by the floating toolbar.
    enum SaveStatus: Equatable {
        /// No save is pending and none has been attempted yet.
        case idle
        /// A save is currently in flight.
        case saving
        /// The most recent save succeeded at the given date.
        case saved(Date)
        /// The most recent save failed with the given message.
        case failed(String)
    }

    /// Notes currently known to the view model, already ordered for display.
    private(set) var notes: [NoteDocument] = []

    /// Identifier of the note the user is editing, if any.
    ///
    /// Changing the selection records the previous identifier in
    /// ``lastActiveNoteID`` so the pending autosave of the outgoing note can be
    /// flushed before the editor switches drawings.
    var selectedNoteID: NoteDocument.ID? {
        didSet {
            if selectedNoteID != oldValue {
                lastActiveNoteID = oldValue
            }
        }
    }

    /// Tool currently highlighted in the toolbar.
    var activeTool: ActiveTool = .pen

    /// Status of the debounced autosave, rendered by the floating toolbar.
    private(set) var saveStatus: SaveStatus = .idle

    /// Last error surfaced by a document operation, shown as an alert when non-nil.
    private(set) var errorMessage: String?

    /// Identifier of the note that was selected before the current one (used to flush its pending save).
    private(set) var lastActiveNoteID: NoteDocument.ID?

    /// The note matching ``selectedNoteID``, or `nil` when nothing is selected.
    var selectedNote: NoteDocument? {
        notes.first { $0.id == selectedNoteID }
    }

    /// Document manager backing every disk operation.
    private let manager: DocumentManager

    /// Pending debounced save. Cancelled and replaced on every edit.
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Most recent unsaved drawing and document staged for debounced save.
    @ObservationIgnored private var pendingSave: (drawing: PKDrawing, note: NoteDocument)?

    /// Creates a view model bound to the shared document manager.
    convenience init() {
        self.init(manager: DocumentManager.shared)
    }

    /// Creates a view model bound to `manager`, bootstraps storage and loads the note list.
    ///
    /// A designated initializer (rather than a default argument) keeps
    /// `DocumentManager.shared` evaluated inside the main-actor-isolated init, so the
    /// reference is valid in the Swift 5 language mode too.
    /// - Parameter manager: Document storage accessor; pass ``DocumentManager/shared``
    ///   (as ``init()`` does) to use the process-wide store.
    init(manager: DocumentManager) {
        self.manager = manager
        try? manager.bootstrap()
        loadNotes()
    }

    /// Reloads the note list from disk, preserving the selection when possible.
    ///
    /// When the previously selected note no longer exists the selection falls
    /// back to the first note in the refreshed list. On failure ``notes`` is
    /// emptied and ``errorMessage`` is populated.
    func loadNotes() {
        do {
            notes = try manager.listNotes()
        } catch {
            errorMessage = error.localizedDescription
            notes = []
        }

        if let selectedNoteID, notes.contains(where: { $0.id == selectedNoteID }) {
            return
        }
        selectedNoteID = notes.first?.id
    }

    /// Loads the PencilKit drawing stored for `note`.
    /// - Parameter note: Note whose drawing should be read from disk.
    /// - Returns: The stored drawing, or `nil` when loading fails (``errorMessage`` is set).
    func loadDrawing(for note: NoteDocument) -> PKDrawing? {
        do {
            return try manager.loadDrawing(for: note)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Creates a new note, inserts it at the top of the list and selects it.
    /// - Returns: The created note, or `nil` when creation fails.
    @discardableResult
    func createNote() -> NoteDocument? {
        do {
            let note = try manager.createNote()
            notes.insert(note, at: 0)
            selectedNoteID = note.id
            return note
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Deletes `note` from disk and from the list, updating the selection if needed.
    /// - Parameter note: Note to remove.
    func delete(_ note: NoteDocument) {
        if pendingSave?.note.id == note.id {
            saveTask?.cancel()
            saveTask = nil
            pendingSave = nil
        }
        do {
            try manager.delete(note)
            notes.removeAll { $0.id == note.id }
            if selectedNoteID == note.id {
                selectedNoteID = notes.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renames `note`, replaces the cached value and restores the modified-date ordering.
    /// - Parameters:
    ///   - note: Note to rename.
    ///   - newTitle: New title to persist.
    func rename(_ note: NoteDocument, to newTitle: String) {
        do {
            let updated = try manager.rename(note, to: newTitle)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
            notes.sort { $0.modifiedAt > $1.modifiedAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Duplicates `note`, inserts the copy at the top of the list and selects it.
    /// - Parameter note: Note to duplicate.
    func duplicate(_ note: NoteDocument) {
        do {
            let copy = try manager.duplicate(note)
            notes.insert(copy, at: 0)
            selectedNoteID = copy.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Debounces a save of `drawing` for `note`.
    ///
    /// Each call cancels the previous pending save, so only the final stroke of
    /// a burst reaches disk. The note list order is intentionally left untouched
    /// while autosaving; only ``loadNotes()``, ``rename(_:to:)`` and
    /// ``duplicate(_:)`` change the ordering.
    /// - Parameters:
    ///   - drawing: Current drawing to persist.
    ///   - note: Note the drawing belongs to.
    func scheduleSave(drawing: PKDrawing, for note: NoteDocument) {
        pendingSave = (drawing, note)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            performSave(drawing: drawing, for: note)
        }
    }

    /// Flushes any pending autosave immediately.
    ///
    /// If an explicit drawing and note are provided, those are persisted.
    /// Otherwise, any drawing previously scheduled for debounced save is written to disk.
    /// - Parameters:
    ///   - drawing: Drawing to persist immediately, or `nil` to flush the scheduled save.
    ///   - note: Note the drawing belongs to, or `nil` to flush the scheduled save.
    func flushPendingSave(drawing: PKDrawing? = nil, for note: NoteDocument? = nil) {
        saveTask?.cancel()
        saveTask = nil

        let targetDrawing = drawing ?? pendingSave?.drawing
        let targetNote = note ?? pendingSave?.note
        guard let targetDrawing, let targetNote else { return }

        performSave(drawing: targetDrawing, for: targetNote)
    }

    /// Performs the synchronous disk write and updates view model state.
    private func performSave(drawing: PKDrawing, for note: NoteDocument) {
        saveStatus = .saving
        do {
            let updated = try manager.save(drawing: drawing, for: note)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
            if pendingSave?.note.id == note.id {
                pendingSave = nil
            }
            saveStatus = .saved(Date())
        } catch {
            saveStatus = .failed(error.localizedDescription)
        }
    }

    /// Exports `note` as a PDF file.
    /// - Parameter note: Note to export.
    /// - Returns: URL of the generated PDF, or `nil` on failure.
    func exportPDF(for note: NoteDocument) -> URL? {
        do {
            return try manager.exportPDF(for: note)
        } catch {
            saveStatus = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Clears ``errorMessage`` after the alert has been dismissed.
    func clearError() {
        errorMessage = nil
    }

    /// Flushes any in-flight debounce to disk (called when the window disappears).
    func cancelPendingWork() {
        flushPendingSave()
    }
}

extension NotesViewModel.SaveStatus {
    /// `true` while a save is in flight.
    var isBusy: Bool {
        if case .saving = self { return true }
        return false
    }

    /// Short human label for the toolbar/accessibility.
    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .saving:
            return "Saving…"
        case .saved:
            return "Saved"
        case .failed:
            return "Save failed"
        }
    }
}
