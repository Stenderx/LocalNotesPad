import Foundation
import XCTest
@testable import LocalNotes

final class NoteDocumentTests: XCTestCase {

    func testDisplayTitleTrimming() {
        let doc = NoteDocument(
            id: UUID(),
            title: "  Meeting Notes \n ",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 100,
            strokeCount: 5
        )
        XCTAssertEqual(doc.displayTitle, "Meeting Notes")
    }

    func testDisplayTitleEmptyFallback() {
        let doc = NoteDocument(
            id: UUID(),
            title: "   \n\t ",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 100,
            strokeCount: 0
        )
        XCTAssertEqual(doc.displayTitle, "Untitled")
    }

    func testSubtitleFormat() {
        let doc = NoteDocument(
            id: UUID(),
            title: "Test",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 2048,
            strokeCount: 1
        )
        XCTAssertTrue(doc.subtitle.contains("1 stroke"))
        XCTAssertTrue(doc.subtitle.contains("KB"))

        let docMultiple = NoteDocument(
            id: UUID(),
            title: "Test",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 4096,
            strokeCount: 12
        )
        XCTAssertTrue(docMultiple.subtitle.contains("12 strokes"))
    }
}
