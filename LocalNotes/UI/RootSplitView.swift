import SwiftUI

/// Root two-column iPad layout: note list on the left, canvas on the right.
///
/// Owns the shared `NotesViewModel` and drives the split-view presentation, the
/// initial library load, autosave flushing across scene transitions and the
/// presentation of user-facing errors.
struct RootSplitView: View {
    /// The single view model shared by the sidebar list and the detail canvas.
    @State private var viewModel = NotesViewModel()

    /// Visibility of the split view's columns, showing both by default.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Most recently observed scene phase, used to detect a return from the background.
    @State private var lastScenePhase: ScenePhase = .active

    /// The hosting scene's phase, observed to safeguard pending autosaves.
    @Environment(\.scenePhase) private var scenePhase

    /// The split layout: note library leading, canvas or calm empty state trailing.
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DocumentListView(viewModel: viewModel)
        } detail: {
            if let note = viewModel.selectedNote {
                NoteDetailView(viewModel: viewModel, note: note)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "square.and.pencil",
                    description: Text("Choose a note from the list or create a new one.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            viewModel.loadNotes()
            if viewModel.selectedNoteID == nil {
                viewModel.selectedNoteID = viewModel.notes.first?.id
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .onDisappear {
            viewModel.cancelPendingWork()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.clearError() } }
            ),
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {
                viewModel.clearError()
            }
        } message: { message in
            Text(message)
        }
    }

    /// Reacts to scene phase transitions: flushes pending autosaves when leaving the
    /// foreground and lightly refreshes the library when returning from the background.
    private func handleScenePhase(_ newPhase: ScenePhase) {
        defer { lastScenePhase = newPhase }

        switch newPhase {
        case .inactive, .background:
            // The root does not own the draft `PKDrawing`, but `scheduleSave(drawing:for:)`
            // captured it when the debounce was armed. Passing `nil` here simply forces the
            // pending debounce to execute immediately, so the captured drawing is persisted
            // before the app is suspended.
            viewModel.flushPendingSave(drawing: nil, for: nil)
        case .active:
            if lastScenePhase == .background {
                viewModel.loadNotes()
            }
        @unknown default:
            break
        }
    }
}

#Preview {
    RootSplitView()
}
