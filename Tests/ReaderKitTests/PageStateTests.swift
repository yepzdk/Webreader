import XCTest
@testable import ReaderKit

// The page-state machine behind the host's flags. Extracted from AppDelegate after 0.10.0
// shipped a bug the ReaderKit-only test target structurally could not catch.
final class PageStateTests: XCTestCase {

    /// The 0.10.0 regression: `loadHTMLString` fires `didStartProvisionalNavigation`, which
    /// cleared the flag the load had just set. The start page ended up on screen with
    /// `isShowingStartPage == false`, so recents clicks were ignored (the handlers are gated
    /// on it) and suggestions never loaded.
    func testOurOwnLoadSurvivesItsOwnNavigationCallbacks() {
        var state = PageState()
        state.willShow(.startPage)
        state.navigationStarted()          // WebKit fires this for our own loadHTMLString
        XCTAssertTrue(state.isShowingStartPage, "our own load must not clear its own flag")
        XCTAssertEqual(state.navigationFinished(), .startPage)
        XCTAssertTrue(state.isShowingStartPage)
        XCTAssertTrue(state.isOwnPage)
    }

    func testNavigatingAwayClearsThePage() {
        var state = PageState()
        state.willShow(.startPage)
        state.navigationStarted()
        state.navigationFinished()
        // Now a real navigation — clicking a link, opening an article.
        state.navigationStarted()
        XCTAssertFalse(state.isShowingStartPage)
        XCTAssertFalse(state.isOwnPage, "a live site must not reach the message handlers")
        XCTAssertNil(state.navigationFinished(), "not ours — the document has to be asked")
    }

    /// The other half: our pages are real history entries, so ⌘[ off Settings lands on the
    /// start page without going through `showStartPage`.
    func testBackForwardRestoresThePageFromItsMarker() {
        var state = PageState()
        state.willShow(.settings)
        state.navigationStarted()
        state.navigationFinished()
        // ⌘[ — a navigation nobody on our side initiated.
        state.navigationStarted()
        XCTAssertFalse(state.isOwnPage)
        XCTAssertNil(state.navigationFinished())
        state.restored(generator: "WebReader Start")
        XCTAssertTrue(state.isShowingStartPage)
        XCTAssertTrue(state.isOwnPage)
    }

    func testAnUnknownGeneratorLeavesThePageAlone() {
        var state = PageState()
        state.navigationStarted()
        state.navigationFinished()
        state.restored(generator: "WordPress 6.4")
        XCTAssertFalse(state.isOwnPage, "someone else's page is never one of ours")
    }

    func testMarkersRoundTripAndTheReaderKeepsItsExactString() {
        // The extraction script matches the reader's marker exactly; changing it would make
        // the reader re-extract (and re-cache) its own rendering.
        XCTAssertEqual(PageState.Page.reader.generator, "WebReader")
        for page in [PageState.Page.startPage, .settings, .reader] {
            XCTAssertEqual(PageState.Page(generator: page.generator!), page)
        }
        XCTAssertNil(PageState.Page.fallback.generator)
    }
}
