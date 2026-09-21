import SwiftUI

/// Application entry point. The whole UI is the two-column `RootSplitView`; there is no
/// document browser because notes live in the app sandbox (`Documents/Notes/`).
@main
struct LocalNotesApp: App {
    /// Tracks the active scene so autosave can be flushed when the app is backgrounded.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootSplitView()
        }
    }
}
