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
        XCTAssertTrue(html.contains("readerPost('readerOpenURL'"))
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
        // The controls live behind the row's own menu at every width, so the keyboard route
        // in is that button — a real disclosure, which `TouchLayoutTests` pins in full.
        XCTAssertTrue(html.contains("className = 'row-menu'"))
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

    func testCarriesTheAppearanceChromeButNeitherList() {
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://x.test/s")
        let html = StartPage.html(appName: "Reader", history: history)
        // The appearance popover is shared verbatim with the reader page.
        XCTAssertTrue(html.contains("id=\"readerAa\""))
        XCTAssertTrue(html.contains("readerPost('readerSettings'"))
        // The recents popover is not: it would be a second, worse copy of the inline list,
        // and the hidden-text panel has no article to group its phrases against (#32).
        XCTAssertFalse(html.contains("id=\"readerRecentsBtn\""))
        XCTAssertFalse(html.contains("id=\"readerRecents\""))
        XCTAssertFalse(html.contains("id=\"readerHiddenBtn\""))
        XCTAssertFalse(html.contains("id=\"readerHiddenList\""))
        // The reader page keeps both, from the same function.
        let reader = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                      content: "<p>x</p>"), history: history)
        XCTAssertTrue(reader.contains("id=\"readerRecentsBtn\""))
        XCTAssertTrue(reader.contains("id=\"readerHiddenBtn\""))
    }

    func testTheChromeScriptDoesNotAssumeTheListsExist() {
        // The shared script runs on a page carrying only the Aa popover, so every reference
        // to the other two is conditional. Without this the whole script throws on load and
        // the start page silently loses its theme, its thumbnails and its settings writes.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains(".filter(function (p) { return p.btn && p.panel; });"))
        XCTAssertTrue(html.contains("if (!hiddenList) { return; }"))
        XCTAssertTrue(html.contains("if (recents) {"))
        // …and the appearance pass still runs, which is what applies theme and data-thumbs.
        XCTAssertTrue(html.contains("window.readerRevealThumbs();"))
        XCTAssertTrue(html.contains("apply();"))
    }

    func testClearHistorySitsInsideTheRecentsColumn() {
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://x.test/s")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertTrue(html.contains("id=\"startClear\""))
        XCTAssertTrue(html.contains("post('readerClear', '')"))
        // A separate id from the popover's #readerClear, which carries the popover's own
        // styling and is handled by the shared chrome script.
        XCTAssertFalse(html.contains("id=\"readerClear\""))
        // Containment is load-bearing, not cosmetic: the handler empties `.recents-column`,
        // so the button only vanishes with the list it clears while it is rendered inside it.
        // One level out and a live Clear history button survives under "No articles yet".
        let column = try? XCTUnwrap(html.range(of: "class=\"recents-column\""))
        let button = try? XCTUnwrap(html.range(of: "id=\"startClear\""))
        let suggested = try? XCTUnwrap(html.range(of: "id=\"suggested\""))
        XCTAssertTrue(column!.lowerBound < button!.lowerBound)
        XCTAssertTrue(button!.lowerBound < suggested!.lowerBound)
        // Clearing swaps in this page's own empty state — heading and list included — and
        // says so, since the offline copies go with it and no list can convey that.
        XCTAssertTrue(html.contains("window.readerEmptyColumn ="))
        XCTAssertTrue(html.contains("column.insertAdjacentHTML('afterbegin', window.readerEmptyColumn)"))
        XCTAssertTrue(html.contains("History cleared, including saved copies."))
    }

    func testNothingToClearWithAnEmptyHistory() {
        XCTAssertFalse(StartPage.html(appName: "Reader").contains("id=\"startClear\""))
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

    func testAListWhereNothingHasAnImageGetsNoColumnAtAll() {
        // Every row stored before #25 has no image, so this is the state after upgrading.
        // Neither an image nor a placeholder: the list looks exactly as it always did.
        var history = ReaderHistory()
        history.record(title: "Plain", url: "https://x.test/b")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertFalse(html.contains("<img class=\"recent-thumb\""))
        // The class is always in the stylesheet; what must be absent is the element.
        XCTAssertFalse(html.contains("<span class=\"recent-thumb recent-thumb-empty\""))
        XCTAssertFalse(html.contains("recents-inline has-thumbs"))
    }

    func testAnImagelessRowInAMixedListGetsThePlaceholder() {
        // The reason the placeholder exists: coverage is uneven by nature, so lists normally
        // mix the two, and a blank column on those rows reads as a failed load.
        var history = ReaderHistory()
        history.record(title: "Plain", url: "https://x.test/b")
        history.record(title: "Illustrated", url: "https://x.test/a", image: "https://x.test/l.jpg")
        let html = StartPage.html(appName: "Reader", history: history)
        XCTAssertTrue(html.contains("recents-inline has-thumbs"))
        XCTAssertTrue(html.contains("recent-thumb recent-thumb-empty"))
        XCTAssertTrue(html.contains("data-src=\"https://x.test/l.jpg\""))
    }

    func testAFailedImageFallsBackToThePlaceholder() {
        // Otherwise a dead URL leaves the browser's broken-image glyph in the row.
        var history = ReaderHistory()
        history.record(title: "Illustrated", url: "https://x.test/a", image: "https://x.test/l.jpg")
        XCTAssertTrue(StartPage.html(appName: "Reader", history: history)
            .contains("this.insertAdjacentHTML('afterend', window.readerThumbPlaceholder)"))
    }

    func testBothListsRenderTheSamePlaceholderMarkup() {
        // One Swift constant, handed to the page script as a quoted literal, so the
        // server-rendered recents rows and the host-delivered suggestion rows cannot drift.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("window.readerThumbPlaceholder = \"<span class="))
        XCTAssertTrue(html.contains("row.insertAdjacentHTML('afterbegin', window.readerThumbPlaceholder)"))
    }

    func testThePlaceholderIsHiddenOutsideAThumbnailList() {
        // It ships in the reader popover's row markup too if a caller ever asks for it; only
        // a list with a column may show it.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains(".recent-thumb-empty { display: none; }"))
        XCTAssertTrue(html.contains(".has-thumbs .recent-thumb-empty {"))
    }

    func testTheRecentsPopoverAsksForThumbnailsToo() {
        // #25 kept them out of the 280px panel; #33 reversed that for consistency with the
        // inline lists, so one row builder still serves both and both now ask for images.
        var history = ReaderHistory()
        history.record(title: "Illustrated", url: "https://x.test/a", image: "https://x.test/l.jpg")
        XCTAssertTrue(ReaderChrome.recentsRows(history, thumbnails: true).contains("recent-thumb"))
        XCTAssertFalse(ReaderChrome.recentsRows(history).contains("recent-thumb"))
        // The popover reserves the column itself, as the inline list does.
        let body = ReaderChrome.recentsBody(history, canClear: true)
        XCTAssertTrue(body.contains("id=\"readerRecentsList\" class=\"has-thumbs\""))
        XCTAssertTrue(body.contains("data-src=\"https://x.test/l.jpg\""))
    }

    func testTheRecentsPopoverReservesNoColumnWithoutImages() {
        // The rule the inline list has always followed: no images in this list, no column,
        // so it looks exactly as it did before #25. An entry carrying an empty string counts
        // as no image — `thumbnail(_:)` renders it as a placeholder.
        var history = ReaderHistory()
        history.record(title: "Plain", url: "https://x.test/b")
        history.record(title: "Blank", url: "https://x.test/c", image: "")
        let body = ReaderChrome.recentsBody(history, canClear: true)
        XCTAssertTrue(body.contains("<div id=\"readerRecentsList\">"))
        XCTAssertFalse(body.contains("has-thumbs"))
        XCTAssertFalse(body.contains("recent-thumb"))
    }

    func testTheClearButtonFollowsTheStoredHistoryNotThePanelsRows() {
        // Read one article and the popover's own list is empty — it excludes the article on
        // screen — but there is history to clear, so the button has to be there.
        XCTAssertTrue(ReaderChrome.recentsBody(ReaderHistory(), canClear: true)
            .contains("id=\"readerClear\""))
        XCTAssertTrue(ReaderChrome.recentsBody(ReaderHistory(), canClear: true)
            .contains("No recent articles"))
        // Nothing stored, nothing to clear.
        XCTAssertFalse(ReaderChrome.recentsBody(ReaderHistory(), canClear: false)
            .contains("id=\"readerClear\""))
    }

    func testTheThumbnailCSSIsSharedByBothPages() {
        // It used to be scoped to the start page by placement, which is exactly what stopped
        // the popover from ever showing one. Both pages now render the same block — including
        // the images-off rules, which are the load-bearing part.
        let reader = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                      content: "<p>x</p>"))
        for rule in [".has-thumbs .recent {", ".recent-thumb {", ".recent-thumb-empty {",
                     ":root[data-thumbs=\"off\"] .recent-thumb { display: none; }",
                     ":root[data-thumbs=\"off\"] .has-thumbs .recent { display: block; }"] {
            XCTAssertTrue(reader.contains(rule), rule)
            XCTAssertTrue(StartPage.html(appName: "Reader").contains(rule), rule)
        }
    }

    func testAClosedPanelFetchesNothing() throws {
        // The popover is closed on every render, and an engine that ignores loading="lazy"
        // inside display:none would otherwise fetch ten thumbnails per article for a panel
        // nobody opened. Opening it is what asks for the images.
        let html = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                    content: "<p>x</p>"))
        XCTAssertTrue(html.contains("if (img.closest('[hidden]')) { return; }"))
        XCTAssertTrue(html.contains("if (which) { window.readerRevealThumbs(); }"))
        // …which only holds if a list is unhidden before it is revealed. Scoped to each
        // page's OWN filler: the chrome script emits its copy first, so an unscoped search
        // finds those two lines on both pages and the start page's ordering goes untested.
        for (page, unhideLine) in [(html, "suggested.hidden = false;"),
                                   (StartPage.html(appName: "Reader"), "section.hidden = false;")] {
            let filler = try XCTUnwrap(page.range(of: "window.readerSetSuggestions = function (items) {",
                                                  options: .backwards))
            let own = page[filler.upperBound...]
            let unhide = try XCTUnwrap(own.range(of: unhideLine))
            let reveal = try XCTUnwrap(own.range(of: "window.readerRevealThumbs()"))
            XCTAssertTrue(unhide.lowerBound < reveal.lowerBound, unhideLine)
        }
    }

    func testSuggestionRowsGetTheSameThumbnailAsRecents() {
        let html = StartPage.html(appName: "Reader")
        // Built by the host callback, since suggestions arrive after the page does.
        XCTAssertTrue(html.contains("thumb.className = 'recent-thumb'"))
        XCTAssertTrue(html.contains("thumb.dataset.src = item.image"))
        XCTAssertTrue(html.contains("thumb.referrerPolicy = 'no-referrer'"))
        // Never a direct src: whether a thumbnail fetches is decided in one place.
        XCTAssertFalse(html.contains("thumb.src = item.image"))
        XCTAssertTrue(html.contains("window.readerRevealThumbs()"))
    }

    func testOnlyOneFunctionEverTurnsAThumbnailIntoAFetch() {
        // The invariant behind "images off means the page requests nothing": rows render with
        // data-src alone, and `readerRevealThumbs` refuses while the setting is off. A second
        // place setting .src would silently reintroduce the requests.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("window.readerRevealThumbs = function ()"))
        XCTAssertTrue(html.contains("if (root.getAttribute('data-thumbs') === 'off') { return; }"))
        XCTAssertEqual(html.components(separatedBy: "img.src = img.dataset.src").count - 1, 1)
    }

    func testSuggestionsReserveTheColumnOnlyWhenTheBatchHasImages() {
        // Same rule as the server-rendered recents list, so a batch of imageless suggestions
        // is laid out exactly as it was before thumbnails existed.
        XCTAssertTrue(StartPage.html(appName: "Reader")
            .contains("list.classList.toggle('has-thumbs'"))
    }

    func testTheAaPopoverHasNoImagesSegment() {
        // "Images / No images" sat among the type and theme controls, where it read as
        // governing the article's own images. It never did — it governed the thumbnails in
        // the recents and suggested lists, which now say so on the settings page.
        let reader = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                      content: "<p>x</p>"))
        for page in [StartPage.html(appName: "Reader"), reader] {
            XCTAssertFalse(page.contains("aria-label=\"Article images\""))
            XCTAssertFalse(page.contains(">Images<"))
            XCTAssertFalse(page.contains(">No images<"))
            // The popover is now type, quotes and theme — nothing about images.
            XCTAssertTrue(page.contains("aria-label=\"Column width\""))
            XCTAssertTrue(page.contains("aria-label=\"Theme\""))
        }
    }

    // MARK: - Which section leads

    func testRecentsLeadWithNothingBakedIntoTheDocument() {
        // The default is the page as it has always been, down to the html tag: a reader who
        // never opens the setting must not be able to tell it exists.
        XCTAssertTrue(StartPage.html(appName: "Reader").contains("<html lang=\"en\">"))
    }

    func testSuggestionsFirstIsBakedInForTheFirstPaint() {
        var settings = ReaderSettings()
        settings.startPageOrder = .suggestionsFirst
        let html = StartPage.html(appName: "Reader", settings: settings)
        XCTAssertTrue(html.contains("<html lang=\"en\" data-order=\"suggestionsFirst\">"))
        // Ordered by CSS, so the document itself is untouched: the suggestions still arrive
        // from the host into the section it wrote in the same place.
        let recents = html.range(of: "class=\"recents-column\"")
        let suggested = html.range(of: "<section id=\"suggested\"")
        XCTAssertNotNil(recents)
        XCTAssertNotNil(suggested)
        XCTAssertTrue(recents!.lowerBound < suggested!.lowerBound)
    }

    func testBothLayoutsHonourTheOrder() {
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains(":root[data-order=\"suggestionsFirst\"] #suggested { order: -1; }"))
        // The two-column layout gives its leading column a tighter heading; `:first-child`
        // cannot follow `order`, so the reversed case says so itself.
        XCTAssertTrue(html.contains(
            ":root[data-order=\"suggestionsFirst\"] .recents-column .section { margin-top: 36px; }"))
        XCTAssertTrue(html.contains(
            ":root[data-order=\"suggestionsFirst\"] #suggested .section { margin-top: 28px; }"))
    }

    func testTheOrderChangesLiveWithoutARerender() {
        // The settings page posts the key, the host pushes the stored settings back
        // (`pushSettings`), and the shared chrome script moves the attribute — the same path
        // the theme and the thumbnails take, so an open start page never has to be rebuilt.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("window.readerSetSettings = function (next)"))
        XCTAssertTrue(html.contains(
            "if (s.startPageOrder === 'suggestionsFirst') { root.setAttribute('data-order', 'suggestionsFirst'); }"))
        XCTAssertTrue(html.contains("else { root.removeAttribute('data-order'); }"))
        // …and the script is seeded with the field, so a pushed payload has one to replace.
        XCTAssertTrue(html.contains("\"startPageOrder\":\"recentsFirst\""))
    }

    // MARK: - Nav slot

    func testSettingsSitsInTheTopLeftNavSlot() {
        // It used to hide in the bottom-left corner (#15). It now occupies the same slot Home
        // takes on every other page, and carries its own handler so the page needs no listener.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("<div class=\"reader-nav\">"))
        XCTAssertTrue(html.contains("id=\"startSettings\""))
        XCTAssertTrue(html.contains("readerPost('readerOpenSettings'"))
        XCTAssertFalse(html.contains("bottom: 14px"))
    }

    func testTheStartPageHasNoHomeButton() {
        // This page *is* home, so the slot carries Settings instead.
        XCTAssertFalse(StartPage.html(appName: "Reader").contains("id=\"readerHomeBtn\""))
    }

    func testBothChromeClustersShareOneBaseline() {
        // The nav slot and the control cluster are separate fixed elements in opposite
        // corners; they only look like one row of chrome while they agree on `top`. Compared
        // rather than pinned to a literal, so the safe-area inset (or any future change to
        // the offset) has to be made in both places or fail here.
        func topOffset(_ css: String) -> String? {
            guard let range = css.range(of: "top: ") else { return nil }
            return css[range.upperBound...].prefix { $0 != ";" }.description
        }
        let nav = topOffset(ReaderChrome.navCSS())
        XCTAssertNotNil(nav)
        XCTAssertEqual(nav, topOffset(ReaderChrome.controlsCSS()))
        // And the offset is safe-area aware, with the explicit 0px fallback that keeps the
        // declaration valid on an engine without `env()`.
        XCTAssertEqual(nav, "calc(14px + var(--safe-top))")
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
