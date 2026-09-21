import SwiftUI

/// Sidebar list of the locally stored notes, newest first.
///
/// Displays `NotesViewModel.notes` in a single-selection `List` and provides
/// the note-management affordances for the app: creating, renaming,
/// duplicating and deleting notes, plus a search field that filters the list
/// by display title.
struct DocumentListView: View {
    /// The observable source of truth for every note shown in this list.
    @Bindable var viewModel: NotesViewModel

    /// The current contents of the search field.
    @State private var searchText = ""

    /// The note awaiting a new title in the rename alert, if any.
    @State private var noteBeingRenamed: NoteDocument?

    /// The draft title bound to the rename alert's text field.
    @State private var renameText = ""

    /// The notes that match the current search text, newest first.
    ///
    /// A blank search returns the unchanged note list; otherwise notes are
    /// matched against the search text with a case- and
    /// diacritic-insensitive comparison on their display title.
    private var filteredNotes: [NoteDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.notes }
        return viewModel.notes.filter { $0.displayTitle.localizedStandardContains(query) }
    }

    var body: some View {
        List(selection: $viewModel.selectedNoteID) {
            ForEach(filteredNotes) { note in
                row(note)
                    .tag(note.id)
            }
        }
        .listStyle(.plain)
        .overlay {
            emptyState
        }
        .navigationTitle("Local Notes")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search notes"
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("Rename Note", isPresented: Binding(get: { noteBeingRenamed != nil }, set: { if !$0 { noteBeingRenamed = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {
                noteBeingRenamed = nil
            }
            Button("Save") {
                if let note = noteBeingRenamed {
                    viewModel.rename(note, to: renameText)
                }
                noteBeingRenamed = nil
            }
        }
    }

    /// A single, selectable row presenting a note's title and metadata.
    ///
    /// A trailing swipe deletes the note; a long press offers rename and
    /// duplicate actions.
    private func row(_ note: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            Text(note.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.delete(note)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                noteBeingRenamed = note
                renameText = note.displayTitle
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                viewModel.duplicate(note)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
        }
    }

    /// The placeholder shown when there are no notes or no search matches.
    ///
    /// The no-notes case is non-interactive so the compose button in the
    /// toolbar stays reachable through the overlay.
    @ViewBuilder
    private var emptyState: some View {
        if viewModel.notes.isEmpty {
            ContentUnavailableView(
                "No Notes",
                systemImage: "note.text",
                description: Text("Tap the compose button to create your first note.")
            )
            .allowsHitTesting(false)
        } else if filteredNotes.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }
}

#Preview {
    DocumentListView(viewModel: NotesViewModel())
}
