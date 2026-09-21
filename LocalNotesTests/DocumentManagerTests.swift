import Foundation
import PencilKit
import XCTest
@testable import LocalNotes

@MainActor
final class DocumentManagerTests: XCTestCase {

    var tempDir: URL!
    var manager: DocumentManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NotesTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = DocumentManager()
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testCreateAndListNote() throws {
        let note = try manager.createNote(title: "Alpha Note")
        XCTAssertEqual(note.title, "Alpha Note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path))

        let metaURL = manager.notesDirectoryURL.appendingPathComponent("\(note.id.uuidString).meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))

        let notes = try manager.listNotes()
        XCTAssertTrue(notes.contains(where: { $0.id == note.id }))

        // Clean up
        try manager.delete(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
    }

    func testRenameNote() throws {
        let note = try manager.createNote(title: "Initial Title")
        let renamed = try manager.rename(note, to: "Updated Title")
        XCTAssertEqual(renamed.title, "Updated Title")
        XCTAssertEqual(renamed.id, note.id)

        // Verify sidecar was updated on disk
        let metaURL = manager.notesDirectoryURL.appendingPathComponent("\(note.id.uuidString).meta.json")
        let data = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(NoteMetadata.self, from: data)
        XCTAssertEqual(meta.title, "Updated Title")

        try manager.delete(renamed)
    }

    func testDuplicateNote() throws {
        let note = try manager.createNote(title: "Original")
        let dup = try manager.duplicate(note)

        XCTAssertNotEqual(dup.id, note.id)
        XCTAssertTrue(dup.title.contains("Original copy"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup.fileURL.path))

        try manager.delete(note)
        try manager.delete(dup)
    }
}
