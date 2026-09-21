import Foundation
import CoreGraphics
import PencilKit
import XCTest
@testable import LocalNotes

final class StraightLineSnapperTests: XCTestCase {

    func testStraightenValidStroke() {
        let p1 = PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        let p2 = PKStrokePoint(location: CGPoint(x: 50, y: 120), timeOffset: 0.5, size: CGSize(width: 4, height: 4), opacity: 1, force: 0.8, azimuth: 0.5, altitude: 0.8)
        let p3 = PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 1.0, size: CGSize(width: 6, height: 6), opacity: 1, force: 1.0, azimuth: 1.0, altitude: 0.6)

        let path = PKStrokePath(controlPoints: [p1, p2, p3], creationDate: Date())
        let ink = PKInk(.pen, color: .black)
        let stroke = PKStroke(ink: ink, path: path)

        guard let snapped = StraightLineSnapper.straightened(stroke) else {
            XCTFail("StraightLineSnapper failed to snap a valid stroke")
            return
        }

        let snappedPath = snapped.path
        XCTAssertEqual(snappedPath.count, StraightLineSnapper.interpolationSteps + 1, "Should have 49 sample points")

        let first = snappedPath[0]
        let last = snappedPath[snappedPath.count - 1]

        XCTAssertEqual(first.location.x, 10, accuracy: 0.001)
        XCTAssertEqual(first.location.y, 10, accuracy: 0.001)
        XCTAssertEqual(last.location.x, 100, accuracy: 0.001)
        XCTAssertEqual(last.location.y, 100, accuracy: 0.001)

        // Check linearity: all points should lie on line from (10,10) to (100,100) -> y = x
        for i in 0..<snappedPath.count {
            let pt = snappedPath[i].location
            XCTAssertEqual(pt.x, pt.y, accuracy: 0.001, "Point \(i) at \(pt) is not collinear")
        }
    }

    func testTooShortStrokeRejected() {
        let p1 = PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0, size: .zero, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let p2 = PKStrokePoint(location: CGPoint(x: 5, y: 5), timeOffset: 0.1, size: .zero, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let path = PKStrokePath(controlPoints: [p1, p2], creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)

        XCTAssertNil(StraightLineSnapper.straightened(stroke), "Strokes shorter than 12pt should be rejected")
    }

    func testSinglePointStrokeRejected() {
        let p1 = PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0, size: .zero, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let path = PKStrokePath(controlPoints: [p1], creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)

        XCTAssertNil(StraightLineSnapper.straightened(stroke), "Single-sample strokes cannot be snapped")
    }
}
