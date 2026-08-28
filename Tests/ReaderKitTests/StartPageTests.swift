import XCTest
@testable import ReaderKit

// Tests for the handler-only start page's pure HTML generation. Mirrors the
// Start page tests: escaping, the URL field, recents, and appearance controls.

final class StartPageTests: XCTestCase {
    func testContainsEscapedAppName() {
        let html = StartPage.html(appName: "Read & Relax <x>")
        XCTAssertTrue(html.contains("Read &amp; Relax &lt;x&gt;"))
        XCTAssertFalse(html.contains("Read & Relax <x>"))
    }

    func testDefaultBackgroundFollowsAppearance() {
        // No manifest color → the light/dark-switching variable, not a fixed color.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("background: var(--bg);"))
    }

    // MARK: - URL entry

    func testOffersURLEntryAndTheShortcutHint() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("id=\"url\""))
        XCTAssertTrue(html.contains("placeholder=\"Paste or type a URL\""))
        XCTAssertTrue(html.contains("<button type=\"submit\">Open</button>"))
        // The keyboard path is taught, not just the button.
        XCTAssertTrue(html.contains("<kbd>⇧⌘O</kbd>"))
        XCTAssertTrue(html.contains("messageHandlers.readerOpenURL.postMessage"))
        // Autofocused so a paste-and-return needs no click.
        XCTAssertTrue(html.contains("autofocus"))
    }

    func testHasAnInlineRejectionMessageHookedToTheHost() {
        // A beep alone is invisible when the user is looking at the field they typed into.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("id=\"error\""))
        XCTAssertTrue(html.contains("role=\"alert\""))
        XCTAssertTrue(html.contains("window.readerURLRejected"))
    }

    // MARK: - Recents

    func testListsRecentsInlineNewestFirst() {
        var history = ReaderHistory()
        history.record(title: "Older piece", url: "https://news.example.com/older")
        history.record(title: "Newest piece", url: "https://blog.example.com/new")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertTrue(html.contains("class=\"recents-inline\""))
        XCTAssertTrue(html.contains("data-url=\"https://blog.example.com/new\""))
        XCTAssertTrue(html.contains("blog.example.com"))
        let newest = html.range(of: "Newest piece")
        let oldest = html.range(of: "Older piece")
        XCTAssertNotNil(newest)
        XCTAssertNotNil(oldest)
        XCTAssertTrue(newest!.lowerBound < oldest!.lowerBound)
    }

    func testRecentTitlesAreEscaped() {
        var history = ReaderHistory()
        history.record(title: "Tips & <script>", url: "https://x.test/a\" onclick=\"alert(1)")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertTrue(html.contains("Tips &amp; &lt;script&gt;"))
        XCTAssertFalse(html.contains("onclick=\"alert(1)\""))
    }

    func testEmptyHistoryKeepsTheRoutingExplanation() {
        // A first-run app genuinely has nothing to list, so it still explains how to
        // get links in rather than showing a bare empty box.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("No articles yet"))
        XCTAssertTrue(html.contains("Choosy"))
        XCTAssertFalse(html.contains("class=\"recents-inline\""))
    }

    func testTitlesGetTwoLinesOnTheStartPage() {
        // One line cuts most Danish headlines before they reveal the subject. The narrow
        // recents popover keeps its single line — this is scoped to the page's own lists.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains(".recents-inline .recent-title, .suggestions .recent-title"))
        XCTAssertTrue(html.contains("-webkit-line-clamp: 2;"))
        // The shared one-line rule must still be there for the popover to inherit.
        XCTAssertTrue(html.contains("display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"))
    }

    // MARK: - Suggestions

    func testSuggestionSectionIsPresentButHiddenUntilTheHostFillsIt() {
        // The page must render and be usable before any feed is fetched, so the section
        // ships empty and hidden; the host reveals it via the callback.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("id=\"suggested\" hidden"))
        XCTAssertTrue(html.contains("class=\"suggestions\""))
        XCTAssertTrue(html.contains("window.readerSetSuggestions"))
    }

    func testOffersAWayIntoSettings() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("id=\"startSettings\""))
        XCTAssertTrue(html.contains("readerOpenSettings"))
    }

    func testSuggestedRowsShareTheRecentsClickPath() {
        // Both lists use `.recent` rows; one delegated listener covers them.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains(".suggestions button[data-url]"))
        XCTAssertTrue(html.contains("post('readerOpen', row.dataset.url)"))
    }

    func testListsShareAGridSoTheyCanSitSideBySide() {
        // A 1200pt window left half the page empty with the lists stacked.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("class=\"lists\""))
        XCTAssertTrue(html.contains("grid-template-columns: 1fr 1fr"))
        // Grid children must be allowed to shrink or long titles stop ellipsizing.
        XCTAssertTrue(html.contains(".lists > * { min-width: 0; }"))
        // The URL field stays narrow and centred regardless.
        XCTAssertTrue(html.contains("class=\"intro\""))
    }

    func testSuggestedRowsCarryFeedbackAndBlockControls() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("readerTopicFeedback"))
        XCTAssertTrue(html.contains("readerBlockHost"))
        XCTAssertTrue(html.contains("'More like this'"))
        XCTAssertTrue(html.contains("'Less like this'"))
        // Controls are revealed on hover but must stay keyboard-reachable.
        XCTAssertTrue(html.contains(".row-actions:focus-within"))
    }

    func testActionsConfirmWithAToast() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("id=\"readerToast\""))
        XCTAssertTrue(html.contains("role=\"status\""))
        XCTAssertTrue(html.contains("window.readerToast"))
        // Each message says what will happen from now on, not just what was clicked.
        XCTAssertTrue(html.contains("More articles like this from now on."))
        XCTAssertTrue(html.contains("No more articles from '"))
    }

    func testGeneratedPagesIdentifyThemselves() {
        // Back/forward restores our own pages without going through the method that built
        // them, so the host re-reads what the document says it is.
        XCTAssertTrue(StartPage.html(appName: "Reader")
            .contains("<meta name=\"generator\" content=\"WebReader Start\">"))
    }

    // MARK: - Shared chrome

    func testCarriesTheSameChromeAsTheReader() {
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://x.test/s")
        let html = StartPage.html(appName: "Reader", history: history)
        // Appearance popover and recents popover, both from ReaderChrome.
        XCTAssertTrue(html.contains("id=\"readerAa\""))
        XCTAssertTrue(html.contains("id=\"readerRecentsBtn\""))
        XCTAssertTrue(html.contains("messageHandlers.readerSettings.postMessage"))
        XCTAssertTrue(html.contains("messageHandlers.readerOpen.postMessage"))
    }

    func testBakedReaderSettingsDriveThePage() {
        var settings = ReaderSettings()
        settings.fontSize = 22
        settings.theme = .sepia
        let html = StartPage.html(appName: "Reader", settings: settings)
        XCTAssertTrue(html.contains("<html lang=\"en\" data-theme=\"sepia\">"))
        XCTAssertTrue(html.contains("--reader-size: 22px;"))
        // The script is seeded with the same settings it renders.
        XCTAssertTrue(html.contains(settings.json))
    }

    func testIsACompleteStandaloneDocument() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    func testHasNoReadingProgressBar() {
        // Reading progress belongs to a long article (#93); this page has no such content,
        // and the shared appearance script must not assume the hook exists here.
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://x.test/s")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertFalse(html.contains("id=\"readerProgress\""))
        XCTAssertFalse(html.contains("window.readerOnLayoutChange = measure"))
        // The guarded call is still present (it's in the shared script) but must be a no-op.
        XCTAssertTrue(html.contains("if (window.readerOnLayoutChange)"))
    }
}
