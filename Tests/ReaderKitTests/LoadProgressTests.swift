import XCTest
@testable import ReaderKit

// Tests for the pure progress-line state logic. The AppKit view + animation are
// hand-verified, per the repo convention.

final class LoadProgressTests: XCTestCase {
    func testIdleOrZeroIsHidden() {
        XCTAssertEqual(LoadProgress.state(for: 0), .hidden)
        XCTAssertEqual(LoadProgress.state(for: -0.1), .hidden) // defensive: negatives hide
    }

    func testCompleteIsFinished() {
        XCTAssertEqual(LoadProgress.state(for: 1.0), .finished)
        XCTAssertEqual(LoadProgress.state(for: 1.5), .finished) // clamp above 1
    }

    func testEarlyProgressShowsAtLeastTheVisibleFloor() {
        // A tiny real value still shows a visible sliver, not a zero-width (invisible) bar.
        guard case .loading(let fraction) = LoadProgress.state(for: 0.01) else {
            return XCTFail("expected loading")
        }
        XCTAssertEqual(fraction, LoadProgress.minimumVisibleFraction, accuracy: 0.0001)
    }

    func testMidProgressTracksTheRealValue() {
        guard case .loading(let fraction) = LoadProgress.state(for: 0.6) else {
            return XCTFail("expected loading")
        }
        XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
    }

    func testJustBelowCompleteIsStillLoading() {
        guard case .loading(let fraction) = LoadProgress.state(for: 0.99) else {
            return XCTFail("expected loading")
        }
        XCTAssertEqual(fraction, 0.99, accuracy: 0.0001)
    }
}
