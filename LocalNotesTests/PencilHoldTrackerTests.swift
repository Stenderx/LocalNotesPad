import Foundation
import CoreGraphics
import XCTest
@testable import LocalNotes

@MainActor
final class PencilHoldTrackerTests: XCTestCase {

    func testHoldTrackerConfiguration() {
        let tracker = PencilHoldTracker(target: nil, action: nil)
        XCTAssertEqual(tracker.holdDuration, 0.75)
        XCTAssertEqual(tracker.maximumMovement, 4.0)
        XCTAssertEqual(tracker.minimumStrokeLength, 8.0)
        XCTAssertFalse(tracker.canPrevent(tracker))
        XCTAssertFalse(tracker.canBePrevented(by: tracker))
    }
}
