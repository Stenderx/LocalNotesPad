import SwiftUI
import UIKit

/// `UIActivityViewController` bridge used to share the exported PDF with the native share sheet
/// (Save to Files, AirDrop, Mail, …).
///
/// `UIViewControllerRepresentable` is `@MainActor`-isolated, so `ShareSheet` and all of its
/// members inherit main-actor isolation under the Swift 6 language mode and need no additional
/// annotations. Present it from SwiftUI with `.sheet(item:)` driven by an ``ExportedItem`` so
/// every freshly generated export gets its own sheet.
struct ShareSheet: UIViewControllerRepresentable {

    /// Activity items handed to the share sheet. A generated PDF `URL` is the expected payload,
    /// but any item type `UIActivityViewController` understands (text, images, …) can be mixed in.
    var items: [Any]

    /// Creates the activity view controller for `items`.
    ///
    /// The controller is deliberately `sourceView`-free: this representable is presented inside a
    /// SwiftUI sheet (`.sheet(item:)`), and the sheet's presentation container supplies the anchor,
    /// so the activity controller renders centred on iPad without the
    /// `UIPopoverPresentationController` exception that an unanchored popover would raise. Arrow
    /// directions are cleared for the same reason — there is no anchor whose edge an arrow could
    /// legitimately point at.
    ///
    /// - Parameter context: The SwiftUI representable context for this instance.
    /// - Returns: A configured activity view controller ready to present.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.permittedArrowDirections = []
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
        }
        return controller
    }

    /// No-op.
    ///
    /// The activity items are immutable for the lifetime of the presented controller: once
    /// `UIActivityViewController` has been created its `activityItems` cannot be changed, so SwiftUI
    /// update passes are intentionally ignored. To share a different payload, dismiss the sheet and
    /// present a new `ShareSheet` (a new ``ExportedItem`` identity does exactly that).
    ///
    /// - Parameters:
    ///   - uiViewController: The activity view controller returned by
    ///     ``makeUIViewController(context:)``.
    ///   - context: The SwiftUI representable context for this instance.
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Intentionally empty.
    }
}

/// Identifiable wrapper so a generated file URL can drive `.sheet(item:)`.
///
/// Every instance mints a fresh `id`, so SwiftUI presents a new sheet for each newly generated
/// export instead of diffing against the previously presented one. `Equatable` compares `url`
/// only, which lets callers cheaply detect that the same file would be exported again.
///
/// `ExportedItem` is a plain, implicitly `Sendable` value type and stays nonisolated so it can be
/// created and compared from any context, including the nonisolated `Identifiable` and `Equatable`
/// requirements. Only ``ShareSheet`` needs main-actor isolation, which it inherits from
/// `UIViewControllerRepresentable`.
struct ExportedItem: Identifiable, Equatable {

    /// Identity used by SwiftUI's `Identifiable` diffing.
    let id: UUID

    /// Location of the file to share, typically the generated PDF.
    let url: URL

    /// Creates a new item with a fresh identity for `url`.
    ///
    /// - Parameter url: Location of the file to hand to the share sheet.
    init(url: URL) {
        self.id = UUID()
        self.url = url
    }

    /// Compares two items by their shared file location.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand item.
    ///   - rhs: The right-hand item.
    /// - Returns: `true` when both items point at the same file `url`.
    static func == (lhs: ExportedItem, rhs: ExportedItem) -> Bool {
        lhs.url == rhs.url
    }
}
