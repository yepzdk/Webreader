import XCTest
@testable import ReaderKit

// Tests for the pure progress-line state logic. The AppKit view + animation are
// hand-verified, per the repo convention.

final class CoverLabelTests: XCTestCase {
    func testTheLabelMatchesTheOtherFullWindowMessage() {
        // The offline page's headline is 20px; the loading cover is the same kind of screen,
        // and both hosts read this rather than each picking a size.
        XCTAssertEqual(LoadProgress.coverLabelSize, 20)
        XCTAssertTrue(OfflineFallback.html(appName: "R", host: nil, kind: .offline)
            .contains("font-size: 20px"))
    }

    func testThereAreEnoughMessagesToNotRepeatConstantly() {
        XCTAssertGreaterThanOrEqual(LoadProgress.coverMessages.count, 10)
        XCTAssertEqual(Set(LoadProgress.coverMessages).count, LoadProgress.coverMessages.count,
                       "duplicates waste a slot")
        XCTAssertTrue(LoadProgress.coverMessages.allSatisfy { !$0.isEmpty })
    }

    func testEveryMessageIsShortEnoughToFitOneLine() {
        // At 20pt a sentence risks clipping in a narrow window, and mixing a two-word message
        // with a nine-word one makes the cover lurch between loads.
        for message in LoadProgress.coverMessages {
            XCTAssertLessThanOrEqual(message.count, 28, "too long: \(message)")
        }
    }

    func testNoEmojiInTheMessages() {
        // Same rule the offline page is held to: line icons, never emoji.
        for message in LoadProgress.coverMessages {
            XCTAssertFalse(message.unicodeScalars.contains { $0.properties.isEmoji },
                           "emoji in: \(message)")
        }
    }

    func testARandomMessageIsAlwaysOneOfTheList() {
        for _ in 0..<200 {
            XCTAssertTrue(LoadProgress.coverMessages.contains(LoadProgress.randomCoverMessage()))
        }
    }

    func testTheCoverMeasuresSilenceNotElapsedTime() {
        // A fixed cap from the moment the cover went up fired mid-load on a slow connection
        // and revealed the site the cover exists to hide (#24). The window is now idle time,
        // re-armed by every progress notification, so it must be short enough to catch a real
        // stall without being so short that a normal gap between packets trips it.
        XCTAssertGreaterThanOrEqual(LoadProgress.coverStallPatience, 3)
        XCTAssertLessThanOrEqual(LoadProgress.coverStallPatience, 10)
    }

    func testTheShimmerIsOneSlowPass() {
        // A spread wider than the label means the highlight starts and ends fully clear of
        // it, so every cycle is one clean pass rather than a band parked mid-word.
        XCTAssertGreaterThan(LoadProgress.coverShimmerSpread, 1)
        XCTAssertGreaterThan(LoadProgress.coverShimmerPeriod, 1)
    }
}

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

    func testScrollProgressCSSReadsTheSharedThickness() {
        // The CSS is generated from the constant, so bumping it can't silently leave the
        // reader page's hairline at the old thickness while the native line moves.
        XCTAssertTrue(
            ReaderChrome.progressCSS().contains("height: \(LoadProgress.lineThickness)px"))
    }

    func testScrollProgressLineIsForegroundNotAccent() {
        // Deliberately a different colour from the accent-coloured native load line: an
        // accent hairline parked mid-page reads as a stuck load.
        let css = ReaderChrome.progressCSS()
        XCTAssertTrue(css.contains("background: var(--fg);"))
        XCTAssertFalse(css.contains("background: var(--accent)"))
    }
}
