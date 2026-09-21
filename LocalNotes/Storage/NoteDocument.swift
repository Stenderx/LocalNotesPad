import Foundation

/// Metadata describing one locally stored `.note` document.
struct NoteDocument: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity of the note; also the file-name stem of its on-disk resources.
    let id: UUID
    /// User-facing title exactly as stored; it may be empty. See ``displayTitle``.
    var title: String
    /// Creation timestamp of the note; preserved across edits.
    var createdAt: Date
    /// Timestamp of the most recent save.
    var modifiedAt: Date
    /// Location of the binary `.note` payload on disk.
    var fileURL: URL
    /// Size of the binary payload in bytes.
    var fileSize: Int64
    /// Number of PencilKit strokes recorded in the drawing.
    var strokeCount: Int
}

/// On-disk JSON sidecar (`<UUID>.meta.json`). Keeps the title independent from the binary
/// PencilKit blob and lets the note list render without decoding drawings.
struct NoteMetadata: Codable, Sendable {
    /// Current on-disk schema version, so the format can evolve safely.
    static let currentSchemaVersion = 1
    /// Schema version used to encode this sidecar.
    var schemaVersion: Int
    /// Stable identity shared with the note's binary payload.
    var id: UUID
    /// User-facing note title as last saved.
    var title: String
    /// Creation timestamp of the note.
    var createdAt: Date
    /// Timestamp of the most recent save.
    var modifiedAt: Date
    /// Number of PencilKit strokes at the time of the last save.
    var strokeCount: Int

    /// Creates sidecar metadata, defaulting to the current schema version.
    ///
    /// - Parameters:
    ///   - id: Stable identity of the note.
    ///   - title: User-facing note title.
    ///   - createdAt: Creation timestamp of the note.
    ///   - modifiedAt: Timestamp of the most recent save.
    ///   - strokeCount: Number of PencilKit strokes recorded for the note.
    ///   - schemaVersion: Schema version to encode; defaults to ``currentSchemaVersion``.
    init(
        id: UUID,
        title: String,
        createdAt: Date,
        modifiedAt: Date,
        strokeCount: Int,
        schemaVersion: Int = NoteMetadata.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.strokeCount = strokeCount
    }
}

extension NoteDocument {
    /// Title shown in the UI; never empty.
    ///
    /// Whitespace and newlines are trimmed from ``title``; when nothing remains,
    /// `"Untitled"` is returned instead.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Secondary list line: abbreviated modification date · byte size · stroke count.
    ///
    /// Produces a single human-readable line, for example
    /// `"Aug 12, 2026 at 4:03 PM · 24 KB · 3 strokes"`.
    var subtitle: String {
        let date = modifiedAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        let strokes = strokeCount == 1 ? "1 stroke" : "\(strokeCount) strokes"
        return "\(date) · \(size) · \(strokes)"
    }
}

extension NoteDocument {
    /// Creates a document value by combining decoded sidecar metadata with the
    /// measured size of its binary payload.
    ///
    /// The memberwise initialiser
    /// `NoteDocument(id:title:createdAt:modifiedAt:fileURL:fileSize:strokeCount:)`
    /// remains available for callers that already hold every field.
    ///
    /// - Parameters:
    ///   - metadata: Decoded sidecar metadata for the note.
    ///   - fileURL: Location of the binary `.note` payload on disk.
    ///   - fileSize: Size of the binary payload in bytes.
    init(metadata: NoteMetadata, fileURL: URL, fileSize: Int64) {
        self.init(
            id: metadata.id,
            title: metadata.title,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            fileURL: fileURL,
            fileSize: fileSize,
            strokeCount: metadata.strokeCount
        )
    }
}
