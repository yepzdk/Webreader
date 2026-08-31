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

    // MARK: - Platform copy

    func testLinuxHintNamesTheLinuxChord() {
        // The GTK host binds Ctrl+Shift+O. ⇧⌘O is not a chord that exists on Linux, and a
        // hint teaching a key the user cannot press is worse than no hint at all.
        let html = StartPage.html(appName: "Reader", platform: .linux)
        XCTAssertTrue(html.contains("<kbd>Ctrl+Shift+O</kbd>"))
        XCTAssertFalse(html.contains("⇧⌘O"))
        // No Mac modifier glyph anywhere on the page, not just in the hint.
        XCTAssertFalse(html.contains("⌘"))
    }

    func testLinuxEmptyRecentsNamesTheLinuxRoute() {
        // Choosy is a Mac application and `open` is a Mac command, so neither belongs on a
        // Linux page: there, links arrive from the desktop's own browser chooser (the app
        // is in it because of its .desktop file) and the command is `webreader <url>`.
        let html = StartPage.html(appName: "Reader", platform: .linux)
        XCTAssertTrue(html.contains("No articles yet"))
        XCTAssertTrue(html.contains("browser chooser"))
        XCTAssertTrue(html.contains("<code>webreader &lt;url&gt;</code>"))
        XCTAssertFalse(html.contains("Choosy"))
    }

    func testMacCopyIsByteForByteWhatItAlwaysWas() {
        // Regression guard for the shipping Mac app: threading `platform` through this copy
        // must not reflow or reword a character of it, whitespace included — the empty
        // paragraph's line break and its six-space continuation are part of the page.
        let html = StartPage.html(appName: "Reader", platform: .macOS)
        XCTAssertTrue(html.contains(
            "<p class=\"hint\">or press <kbd>⇧⌘O</kbd> to open a copied link</p>"))
        XCTAssertTrue(html.contains("""
            <p class="hint empty">No articles yet. Route links here from your browser picker
                  (e.g. Choosy), or open one from the command line with <code>open</code>.</p>
            """))
    }

    func testTheDefaultPlatformIsStillMacOSToTheByte() {
        // Every AppKit call site omits `platform:`, so the default *is* the Mac app's page.
        // Comparing the two whole documents keeps that honest without this test having to
        // pin bytes it has no opinion about.
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://x.test/s")
        XCTAssertEqual(StartPage.html(appName: "Reader", history: history),
                       StartPage.html(appName: "Reader", history: history, platform: .macOS))
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

    // MARK: - Recents thumbnails (#25)

    func testARecentWithALeadImageGetsAThumbnail() {
        var history = ReaderHistory()
        history.record(title: "Illustrated", url: "https://x.test/a",
                       image: "https://x.test/lead.jpg?w=1&h=2")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertTrue(html.contains("class=\"recent-thumb\""))
        // The src is withheld until the appearance script applies the setting, so the page
        // fetches nothing while article images are off.
        XCTAssertTrue(html.contains("data-src=\"https://x.test/lead.jpg?w=1&amp;h=2\""))
        XCTAssertFalse(html.contains("<img class=\"recent-thumb\" src="))
        XCTAssertTrue(html.contains("referrerpolicy=\"no-referrer\""))
    }

    func testARecentWithoutALeadImageGetsNoBox() {
        // Every row stored before #25 has no image; reserving space would render the whole
        // list as grey rectangles on first upgrade.
        var history = ReaderHistory()
        history.record(title: "Plain", url: "https://x.test/b")
        // The class is always in the stylesheet; what must be absent is the element.
        XCTAssertFalse(StartPage.html(appName: "Reader", history: history)
            .contains("<img class=\"recent-thumb\""))
    }

    func testTheRecentsPopoverNeverGetsThumbnails() {
        // One row builder serves the start page and the reader's 280px popover; only the
        // start page asks for images.
        var history = ReaderHistory()
        history.record(title: "Illustrated", url: "https://x.test/a", image: "https://x.test/l.jpg")
        XCTAssertFalse(ReaderChrome.recentsRows(history).contains("recent-thumb"))
        XCTAssertTrue(ReaderChrome.recentsRows(history, thumbnails: true).contains("recent-thumb"))
    }

    func testTheImagesToggleIsOnTheStartPageOnly() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("data-key=\"startPageImages\""))
        // The Aa popover is shared verbatim with the reader page, where the control would
        // govern rows that aren't there.
        XCTAssertFalse(ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                        content: "<p>x</p>"))
            .contains("data-key=\"startPageImages\""))
    }

    // MARK: - Nav slot

    func testSettingsSitsInTheTopLeftNavSlot() {
        // It used to hide in the bottom-left corner (#15). It now occupies the same slot Home
        // takes on every other page, and carries its own handler so the page needs no listener.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("<div class=\"reader-nav\">"))
        XCTAssertTrue(html.contains("id=\"startSettings\""))
        XCTAssertTrue(html.contains("messageHandlers.readerOpenSettings.postMessage"))
        XCTAssertFalse(html.contains("bottom: 14px"))
    }

    func testTheStartPageHasNoHomeButton() {
        // This page *is* home, so the slot carries Settings instead.
        XCTAssertFalse(StartPage.html(appName: "Reader").contains("id=\"readerHomeBtn\""))
    }

    func testBothChromeClustersShareOneBaseline() {
        // The nav slot and the control cluster are separate fixed elements in opposite
        // corners; they only look like one row of chrome while they agree on `top`.
        let nav = ReaderChrome.navCSS()
        let controls = ReaderChrome.controlsCSS()
        XCTAssertTrue(nav.contains("top: 14px; left: 14px;"))
        XCTAssertTrue(controls.contains("top: 14px; right: 14px;"))
    }

    func testTheNavSlotIsNotAControlCluster() {
        // controlsScript dismisses an open popover on any click outside `.reader-controls`.
        // Reusing that class for the nav slot would silently break the dismissal.
        XCTAssertFalse(ReaderChrome.navCSS().contains(".reader-controls"))
        XCTAssertFalse(ReaderChrome.navHome().contains("reader-controls"))
        XCTAssertFalse(ReaderChrome.navSettings().contains("reader-controls"))
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
