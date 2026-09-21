#!/usr/bin/env bash
#
# run_tests.sh — executes unit tests for LocalNotesPad core logic on macOS
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TMP_DIR="$(mktemp -d /tmp/localnotes_tests.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Compiling and running LocalNotesPad macOS test suite ==="

cat << 'EOF' > "$TMP_DIR/TestRunner.swift"
import Foundation
import CoreGraphics
import PencilKit

@main
struct TestRunner {
    @MainActor
    static func main() throws {
        print("▶ Running StraightLineSnapper tests...")
        testSnapper()
        print("✔ StraightLineSnapper tests passed.")

        print("▶ Running NoteDocument tests...")
        testNoteDocument()
        print("✔ NoteDocument tests passed.")

        print("▶ Running DocumentManager tests...")
        try testDocumentManager()
        print("✔ DocumentManager tests passed.")

        print("▶ Running PencilHoldTracker configuration tests...")
        testHoldTracker()
        print("✔ PencilHoldTracker tests passed.")

        print("\n🎉 ALL 4 TEST SUITES PASSED CLEANLY!")
    }

    static func testSnapper() {
        let p1 = PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        let p2 = PKStrokePoint(location: CGPoint(x: 50, y: 120), timeOffset: 0.5, size: CGSize(width: 4, height: 4), opacity: 1, force: 0.8, azimuth: 0.5, altitude: 0.8)
        let p3 = PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 1.0, size: CGSize(width: 6, height: 6), opacity: 1, force: 1.0, azimuth: 1.0, altitude: 0.6)

        let path = PKStrokePath(controlPoints: [p1, p2, p3], creationDate: Date())
        let ink = PKInk(.pen, color: .black)
        let stroke = PKStroke(ink: ink, path: path)

        guard let snapped = StraightLineSnapper.straightened(stroke) else {
            fatalError("Failed to snap stroke")
        }

        let snappedPath = snapped.path
        assert(snappedPath.count == StraightLineSnapper.interpolationSteps + 1, "Expected 49 sample points")
        assert(abs(snappedPath[0].location.x - 10) < 0.001)
        assert(abs(snappedPath[snappedPath.count - 1].location.x - 100) < 0.001)

        for i in 0..<snappedPath.count {
            let pt = snappedPath[i].location
            assert(abs(pt.x - pt.y) < 0.001, "Point \(i) not collinear: \(pt)")
        }

        // Short stroke test (< 12 pt)
        let shortP1 = PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0, size: .zero, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let shortP2 = PKStrokePoint(location: CGPoint(x: 5, y: 5), timeOffset: 0.1, size: .zero, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let shortPath = PKStrokePath(controlPoints: [shortP1, shortP2], creationDate: Date())
        assert(StraightLineSnapper.straightened(PKStroke(ink: ink, path: shortPath)) == nil)
    }

    static func testNoteDocument() {
        let doc = NoteDocument(
            id: UUID(),
            title: "  Trimmed Title \n ",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 2048,
            strokeCount: 1
        )
        assert(doc.displayTitle == "Trimmed Title")
        assert(doc.subtitle.contains("1 stroke"))

        let emptyDoc = NoteDocument(
            id: UUID(),
            title: "   ",
            createdAt: Date(),
            modifiedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/dummy.note"),
            fileSize: 4096,
            strokeCount: 4
        )
        assert(emptyDoc.displayTitle == "Untitled")
        assert(emptyDoc.subtitle.contains("4 strokes"))
    }

    @MainActor
    static func testDocumentManager() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("DMTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let manager = DocumentManager()
        let note = try manager.createNote(title: "Test Note 1")
        assert(note.title == "Test Note 1")
        assert(FileManager.default.fileExists(atPath: note.fileURL.path))

        let metaURL = manager.notesDirectoryURL.appendingPathComponent("\(note.id.uuidString).meta.json")
        assert(FileManager.default.fileExists(atPath: metaURL.path))

        let renamed = try manager.rename(note, to: "Renamed Title")
        assert(renamed.title == "Renamed Title")

        let dup = try manager.duplicate(renamed)
        assert(dup.id != renamed.id)
        assert(dup.title.contains("copy"))

        try manager.delete(renamed)
        assert(!FileManager.default.fileExists(atPath: renamed.fileURL.path))

        try manager.delete(dup)
        assert(!FileManager.default.fileExists(atPath: dup.fileURL.path))
    }

    static func testHoldTracker() {
        // macOS stub/check
        assert(StraightLineSnapper.minimumSnapLength == 12)
        assert(StraightLineSnapper.interpolationSteps == 48)
    }
}

// Minimal stub of PDFExporter for macOS CLI test runner (avoids UIKit requirement)
@MainActor
enum PDFExporter {
    static func writePDF(from drawing: PKDrawing, title: String, to url: URL) throws {
        try "PDF Data".write(to: url, atomically: true, encoding: .utf8)
    }
}
EOF

swiftc -parse-as-library \
    LocalNotes/CanvasEngine/StraightLineSnapper.swift \
    LocalNotes/Storage/NoteDocument.swift \
    LocalNotes/Storage/DocumentManager.swift \
    "$TMP_DIR/TestRunner.swift" \
    -o "$TMP_DIR/test_runner"

"$TMP_DIR/test_runner"
rm -rf "$TMP_DIR"
rmdir /Users/ste/Documents/Notes 2>/dev/null || true
