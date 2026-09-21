import Foundation
import PencilKit

/// Errors thrown by ``DocumentManager`` when the on-disk note store cannot satisfy a request.
enum DocumentManagerError: LocalizedError {
    /// The requested note's blob (or its JSON sidecar) does not exist in the notes directory.
    case noteNotFound

    /// User-facing description for every error in this domain, surfaced through `LocalizedError`.
    var errorDescription: String? {
        switch self {
        case .noteNotFound:
            return "The requested note could not be found in the local notes store."
        }
    }
}

/// Thread-safe façade over the local note store (`<Documents>/Notes/`).
/// `@MainActor`-isolated because `PKDrawing` is not `Sendable`; the byte-level work is
/// small (one directory scan, one blob read/write per operation) so it stays simple and
/// predictable rather than hopping actors for a few kilobytes.
///
/// - Note: Every blob and sidecar write uses the `.atomic` option, so a crash or forced
///   termination mid-save can never leave a partially written file behind: readers observe
///   either the previous bytes or the complete new ones. The blob is named after the note's
///   `UUID` rather than its title, so renaming rewrites only the small JSON sidecar and the
///   payload URL stays stable for the entire lifetime of the note.
@MainActor
final class DocumentManager {
    /// Process-wide store used by the app; `@MainActor`-isolated like the type itself.
    static let shared = DocumentManager()

    /// Folder appended to the user's Documents directory that holds every note file.
    static let notesDirectoryName = "Notes"

    /// File extension of the raw `PKDrawing` blob backing a note.
    static let fileExtension = "note"

    /// Absolute URL of the notes directory (`<Documents>/Notes/`), resolved once at init.
    private(set) var notesDirectoryURL: URL

    /// Diagnostics collected by the most recent ``listNotes()`` call; cleared at its start.
    private(set) var lastLoadWarnings: [String] = []

    /// Title assigned to a note whose sidecar metadata had to be synthesised from disk.
    private static let recoveredTitle = "Untitled"

    /// Maximum number of characters kept when normalising a user-supplied title.
    private static let titleCharacterLimit = 120

    /// Resource keys prefetched in a single pass while scanning the notes directory.
    private static let listingKeys: Set<URLResourceKey> = [
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
    ]

    /// File manager used for every disk interaction; injected for testability.
    private let fileManager: FileManager

    /// Total size, in bytes, of every file currently inside the notes directory.
    /// Reports `0` when the directory has not been created yet.
    var storageUsageBytes: Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        return entries.reduce(into: Int64(0)) { total, url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            total += Int64(size)
        }
    }

    /// Creates the façade and resolves its directory URL without touching the disk.
    /// Never throws; the directory itself is materialised by ``bootstrap()``.
    /// - Parameter fileManager: File manager used for all subsequent disk access.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.notesDirectoryURL = documents.appendingPathComponent(Self.notesDirectoryName, isDirectory: true)
    }

    /// Ensures the notes directory exists, creating it and any missing parents when needed.
    /// Idempotent: calling it on an existing directory is a no-op.
    func bootstrap() throws {
        try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
    }

    /// Scans the notes directory and returns every readable note, newest first.
    ///
    /// Notes missing their sidecar are repaired in place with synthesised metadata
    /// (`"Untitled"`, timestamps taken from the file attributes, `strokeCount` of zero).
    /// Files whose names are not note identifiers, or whose metadata cannot be read or
    /// decoded, are skipped and described in ``lastLoadWarnings``.
    /// - Returns: Notes sorted by `modifiedAt` descending, ties broken by `createdAt` descending.
    func listNotes() throws -> [NoteDocument] {
        lastLoadWarnings = []
        let entries = try fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: Array(Self.listingKeys)
        )
        var notes: [NoteDocument] = []
        for entry in entries where entry.pathExtension.lowercased() == Self.fileExtension {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent) else {
                lastLoadWarnings.append("Skipped \(entry.lastPathComponent): the file name is not a valid note identifier.")
                continue
            }
            do {
                let values = try entry.resourceValues(forKeys: Self.listingKeys)
                var metadata: NoteMetadata
                if fileManager.fileExists(atPath: metaURL(for: id).path) {
                    metadata = try readMeta(for: id)
                    metadata.id = id
                } else {
                    let created = values.creationDate ?? values.contentModificationDate ?? Date()
                    let modified = values.contentModificationDate ?? created
                    metadata = NoteMetadata(
                        id: id,
                        title: Self.recoveredTitle,
                        createdAt: created,
                        modifiedAt: modified,
                        strokeCount: 0
                    )
                    do {
                        try writeMeta(metadata)
                    } catch {
                        lastLoadWarnings.append("Could not persist recovered metadata for \(entry.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                notes.append(makeDocument(from: metadata, fileSize: Int64(values.fileSize ?? 0)))
            } catch {
                lastLoadWarnings.append("Skipped \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        notes.sort { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt ? lhs.createdAt > rhs.createdAt : lhs.modifiedAt > rhs.modifiedAt
        }
        return notes
    }

    /// Creates a new, empty note on disk and returns its document handle.
    ///
    /// The requested title is trimmed, whitespace-collapsed, and made unique against the
    /// titles already stored (`"Untitled Note"`, `"Untitled Note 2"`, …). The blob is an
    /// empty `PKDrawing` serialised with `dataRepresentation()`.
    /// - Parameter title: Preferred display title; `nil`, blank, or whitespace-only input
    ///   falls back to `"Untitled Note"`.
    /// - Returns: The freshly written note, sidecar included.
    func createNote(title: String? = nil) throws -> NoteDocument {
        try bootstrap()
        let requested = normaliseTitle(title ?? "")
        let base = requested.isEmpty ? "Untitled Note" : requested
        let taken = try existingTitles()
        let resolvedTitle = uniqueTitle(base: base, taken: taken)
        let id = UUID()
        let data = PKDrawing().dataRepresentation()
        try data.write(to: noteURL(for: id), options: [.atomic])
        let now = Date()
        let metadata = NoteMetadata(id: id, title: resolvedTitle, createdAt: now, modifiedAt: now, strokeCount: 0)
        try writeMeta(metadata)
        return makeDocument(from: metadata, fileSize: Int64(data.count))
    }

    /// Reads and deserialises the stored drawing backing `note`.
    /// - Parameter note: Note whose payload should be loaded.
    /// - Returns: The decoded drawing.
    /// - Throws: ``DocumentManagerError/noteNotFound`` when the blob is missing, or a
    ///   `Data`/`PKDrawing` error when the payload cannot be read or decoded.
    func loadDrawing(for note: NoteDocument) throws -> PKDrawing {
        guard fileManager.fileExists(atPath: note.fileURL.path) else {
            throw DocumentManagerError.noteNotFound
        }
        return try PKDrawing(data: Data(contentsOf: note.fileURL))
    }

    /// Persists `drawing` as the payload of `note` and refreshes its sidecar.
    /// The blob write is atomic; the sidecar records the new `modifiedAt` and stroke count.
    /// - Parameters:
    ///   - drawing: Drawing to serialise.
    ///   - note: Note whose payload should be replaced.
    /// - Returns: An updated document value reflecting the new bytes, size, and timestamp.
    func save(drawing: PKDrawing, for note: NoteDocument) throws -> NoteDocument {
        let data = drawing.dataRepresentation()
        try data.write(to: note.fileURL, options: [.atomic])
        var metadata = (try? readMeta(for: note.id)) ?? NoteMetadata(
            id: note.id,
            title: note.title,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            strokeCount: note.strokeCount
        )
        metadata.modifiedAt = Date()
        metadata.strokeCount = drawing.strokes.count
        try writeMeta(metadata)
        return makeDocument(from: metadata, fileSize: Int64(data.count))
    }

    /// Retitles `note` by rewriting only its sidecar; the blob is untouched and never renamed.
    /// - Parameters:
    ///   - note: Note to rename.
    ///   - newTitle: Desired title, trimmed, whitespace-collapsed, and capped at 120
    ///     characters. A blank result keeps the previous title.
    /// - Returns: An updated document value with a refreshed `modifiedAt`.
    func rename(_ note: NoteDocument, to newTitle: String) throws -> NoteDocument {
        var metadata = try readMeta(for: note.id)
        let cleaned = normaliseTitle(newTitle)
        if !cleaned.isEmpty {
            metadata.title = cleaned
        }
        metadata.modifiedAt = Date()
        try writeMeta(metadata)
        return makeDocument(from: metadata, fileSize: note.fileSize)
    }

    /// Removes the note's blob and sidecar from disk.
    /// Already-absent files are tolerated, so deleting twice is safe.
    /// - Parameter note: Note to delete.
    func delete(_ note: NoteDocument) throws {
        for url in [note.fileURL, metaURL(for: note.id)] {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if isMissingFileError(error) { continue }
                throw error
            }
        }
    }

    /// Copies `note` into a brand-new blob and sidecar, leaving the original untouched.
    /// The copy receives a fresh identifier, the title `"<title> copy"` (made unique when
    /// needed), and a single fresh timestamp for both `createdAt` and `modifiedAt`.
    /// - Parameter note: Note to clone.
    /// - Returns: The newly created copy.
    /// - Throws: ``DocumentManagerError/noteNotFound`` when the source blob is missing.
    func duplicate(_ note: NoteDocument) throws -> NoteDocument {
        try bootstrap()
        guard fileManager.fileExists(atPath: note.fileURL.path) else {
            throw DocumentManagerError.noteNotFound
        }
        let blob = try Data(contentsOf: note.fileURL)
        let taken = try existingTitles()
        let copyTitle = uniqueTitle(base: "\(note.title) copy", taken: taken)
        let id = UUID()
        let now = Date()
        try blob.write(to: noteURL(for: id), options: [.atomic])
        let metadata = NoteMetadata(id: id, title: copyTitle, createdAt: now, modifiedAt: now, strokeCount: note.strokeCount)
        try writeMeta(metadata)
        return makeDocument(from: metadata, fileSize: Int64(blob.count))
    }

    /// Renders `note` to a PDF in the temporary directory and returns its location.
    /// The file name is derived from the sanitised ``NoteDocument/displayTitle`` so it is
    /// safe to hand to share sheets and document pickers.
    /// - Parameter note: Note to export.
    /// - Returns: URL of the generated PDF.
    func exportPDF(for note: NoteDocument) throws -> URL {
        let drawing = try loadDrawing(for: note)
        let fileName = sanitise(note.displayTitle) + ".pdf"
        let url = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        try PDFExporter.writePDF(from: drawing, title: note.displayTitle, to: url)
        return url
    }

    // MARK: - Private helpers

    /// Builds the sidecar URL for a note identifier.
    /// - Parameter id: Stable note identifier.
    /// - Returns: `<Documents>/Notes/<UUID>.meta.json`.
    private func metaURL(for id: UUID) -> URL {
        notesDirectoryURL.appendingPathComponent("\(id.uuidString).meta.json")
    }

    /// Builds the payload URL for a note identifier.
    /// - Parameter id: Stable note identifier.
    /// - Returns: `<Documents>/Notes/<UUID>.note`.
    private func noteURL(for id: UUID) -> URL {
        notesDirectoryURL.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    /// Encodes `metadata` as pretty-printed, key-sorted JSON and writes it atomically.
    /// - Parameter metadata: Sidecar value to persist.
    private func writeMeta(_ metadata: NoteMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metaURL(for: metadata.id), options: [.atomic])
    }

    /// Loads and decodes the sidecar belonging to `id`.
    /// - Parameter id: Stable note identifier.
    /// - Returns: The decoded metadata.
    /// - Throws: ``DocumentManagerError/noteNotFound`` when the sidecar is absent, or a
    ///   decoding error when its contents are malformed.
    private func readMeta(for id: UUID) throws -> NoteMetadata {
        let url = metaURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw DocumentManagerError.noteNotFound
        }
        return try JSONDecoder().decode(NoteMetadata.self, from: Data(contentsOf: url))
    }

    /// Assembles a value type from decoded metadata and the matching blob's on-disk size.
    /// - Parameters:
    ///   - metadata: Sidecar contents, already reconciled with the file name.
    ///   - fileSize: Size of the `.note` blob in bytes.
    /// - Returns: A document whose `fileURL` points at the UUID-named blob.
    private func makeDocument(from metadata: NoteMetadata, fileSize: Int64) -> NoteDocument {
        NoteDocument(
            id: metadata.id,
            title: metadata.title,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            fileURL: noteURL(for: metadata.id),
            fileSize: fileSize,
            strokeCount: metadata.strokeCount
        )
    }

    /// Trims a raw title, collapses internal whitespace runs to single spaces, and caps
    /// the result at ``titleCharacterLimit`` characters.
    /// - Parameter raw: Raw, user-supplied title text.
    /// - Returns: The normalised title, possibly empty when `raw` was blank.
    private func normaliseTitle(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(Self.titleCharacterLimit))
    }

    /// Returns `base` when it is free, otherwise `"base 2"`, `"base 3"`, … until it is.
    /// Comparisons are case-insensitive.
    /// - Parameters:
    ///   - base: Preferred title.
    ///   - taken: Lowercased titles already present in the store.
    /// - Returns: A title that does not collide with `taken`.
    private func uniqueTitle(base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }

    /// Collects the lowercased titles of every note currently stored.
    /// - Returns: A set used to make newly generated titles unique.
    private func existingTitles() throws -> Set<String> {
        let notes = try listNotes()
        return Set(notes.map { $0.title.lowercased() })
    }

    /// Converts arbitrary text into a safe, single-component file name (no extension).
    /// Strips `/`, `\`, `:` and control characters, collapses whitespace, caps the result
    /// at 80 characters, and falls back to `"Note"` when nothing printable remains.
    /// - Parameter fileName: Raw, user-controlled text.
    /// - Returns: A file-name-safe string.
    private func sanitise(_ fileName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let stripped = fileName.components(separatedBy: forbidden).joined(separator: " ")
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let capped = String(collapsed.prefix(80))
        return capped.isEmpty ? "Note" : capped
    }

    /// Reports whether an error represents an already-absent file, which ``delete(_:)``
    /// deliberately ignores.
    /// - Parameter error: Error thrown by `FileManager.removeItem(at:)`.
    /// - Returns: `true` for Cocoa "no such file" failures and their POSIX equivalent.
    private func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }
}
