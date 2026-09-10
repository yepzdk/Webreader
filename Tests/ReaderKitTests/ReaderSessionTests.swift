import XCTest
@testable import ReaderKit

/// The reader's decisions, with no web view anywhere.
///
/// This is what all three hosts run, so the things asserted here are the things that would
/// otherwise have to be checked by hand on three platforms: whether a page is offered to
/// Readability, whether a live site can reach the store, what a failed load falls back to.
/// The WebKit tests still exist and still click real pages — they prove the *wiring*; these
/// prove the rules.
final class ReaderSessionTests: XCTestCase {
    private var directory: URL!
    private var store: MemoryStore!
    private var session: ReaderSession!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderSessionTests-\(UUID().uuidString)")
        store = MemoryStore()
        session = ReaderSession(store: store, cache: ArticleCache(directory: directory),
                                appName: "WebReader", platform: .android)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let page = URL(string: "https://example.test/article")!
    private let article = Article(title: "An article", byline: nil, siteName: nil,
                                  content: "<p>Body</p>")

    /// Drives the session to the point where the reader is on screen, which most of the
    /// interesting rules are gated on.
    private func enterReader() {
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")
        _ = session.extractionResult(url: page, result: extracted, title: nil)
        _ = session.navigationFinished(url: page, generator: PageState.Page.reader.generator ?? "")
    }
    /// What the extraction script hands back: the article as JSON, which is the same shape
    /// `ArticleCache` keeps on disk.
    private var extracted: String {
        String(decoding: try! JSONEncoder().encode(article), as: UTF8.self)
    }

    func testAFinishedWebPageIsOfferedToReadability() {
        _ = session.openIncoming(page)
        let commands = session.navigationFinished(url: page, generator: "")
        guard case let .extract(url, script)? = commands.first else {
            return XCTFail("a real page must be offered to the reader, got \(commands)")
        }
        XCTAssertEqual(url, page)
        XCTAssertTrue(script.contains("isProbablyReaderable"))
    }

    func testAnExtractedArticleIsRecordedUnderItsCleanedURL() {
        // The tracking parameters go before the row is written, because reopening the row
        // routes back through `openIncoming`, which cleans — recording the raw URL would make
        // the replay look like a different article.
        let tracked = URL(string: "https://example.test/article?utm_source=newsletter")!
        _ = session.openIncoming(tracked)
        let commands = session.extractionResult(url: page, result: extracted, title: nil)
        guard case .show? = commands.first else {
            return XCTFail("an article must be rendered, got \(commands)")
        }
        XCTAssertEqual(ReaderStore.history(store: store).entries.map(\.url),
                       ["https://example.test/article"])
    }

    func testAPageThatIsNotAnArticleIsLeftAlone() {
        // Silence, not an error page: the site itself is the honest answer to "this does not
        // extract", and it is already on screen.
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")
        XCTAssertEqual(session.extractionResult(url: page, result: nil, title: nil), [])
        XCTAssertTrue(ReaderStore.history(store: store).entries.isEmpty)
    }

    func testALiveSiteCannotReachTheStore() {
        // The gate that matters most: message handlers are session-wide, so without it any
        // page's JavaScript could clear the reader's history.
        var history = ReaderHistory()
        history.record(title: "Kept", url: "https://example.test/kept", at: 100)
        ReaderStore.setHistory(history, store: store)
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")

        XCTAssertEqual(session.message("readerClear", body: .text("")), [])

        XCTAssertEqual(ReaderStore.history(store: store).entries.map(\.title), ["Kept"])
    }

    func testClearingHistoryFromOurOwnPageLeavesATombstone() {
        // An empty list would be merged away by any device that still has the rows; the
        // timestamp is what makes the clear win.
        var history = ReaderHistory()
        history.record(title: "Read", url: "https://example.test/read", at: 100)
        ReaderStore.setHistory(history, store: store)
        _ = session.showStartPage()
        _ = session.navigationFinished(url: nil, generator: "WebReader Start")

        _ = session.message("readerClear", body: .text(""))

        XCTAssertTrue(ReaderStore.history(store: store).entries.isEmpty)
        XCTAssertNotNil(ReaderStore.history(store: store).clearedAt)
    }

    func testASavedCopyBeatsTheOfflinePage() {
        // The article is what was asked for, and a reload fetches the live page again once
        // the network is back.
        session.cache.store(article, for: page)
        _ = session.openIncoming(page)

        let commands = session.loadFailed(url: page, code: -1009)

        guard case let .show(html, baseURL)? = commands.first else {
            return XCTFail("a cached article must be rendered, got \(commands)")
        }
        XCTAssertEqual(baseURL, page)
        XCTAssertTrue(html.contains("An article"))
        XCTAssertFalse(session.isShowingFallback)
    }
    func testAFailureWithNothingSavedShowsTheOfflinePage() {
        // -1003 is "cannot find host", the one kind whose message names the host — so this
        // asserts the classification and the interpolation in one go.
        let commands = session.loadFailed(url: page, code: -1003)
        guard case let .show(html, baseURL)? = commands.first else {
            return XCTFail("a failed load must land somewhere, got \(commands)")
        }
        XCTAssertNil(baseURL)
        XCTAssertTrue(html.contains("example.test"))
        XCTAssertTrue(session.isShowingFallback)
    }

    func testACancelledLoadIsNotAFailure() {
        // -999 is what a navigation replaced by a newer one reports; drawing an error page
        // for it would replace the page the user just asked for.
        XCTAssertEqual(session.loadFailed(url: page, code: -999), [])
        XCTAssertFalse(session.isShowingFallback)
    }

    func testARecentsRowWithASavedCopyOpensWithoutALoad() {
        // No network for something already on disk. Only recents take this shortcut — an
        // incoming link is "read this now" and always loads live.
        session.cache.store(article, for: page)
        _ = session.showStartPage()
        _ = session.navigationFinished(url: nil, generator: "WebReader Start")

        let commands = session.message("readerOpen", body: .text(page.absoluteString))

        XCTAssertFalse(commands.contains { if case .load = $0 { return true } else { return false } })
        guard case .show? = commands.first else {
            return XCTFail("a saved article must render straight from disk, got \(commands)")
        }
    }

    func testRatingNeedsAHeadlineToLearnFrom() {
        // Terms come from the title; without one there is nothing to learn, and filing the
        // rating anyway would attach the previous article's terms to this URL.
        enterReader()
        session.readerArticleTitle = nil
        XCTAssertEqual(session.message("readerRate", body: .text("more")), [])
        XCTAssertTrue(ReaderStore.topics(store: store).weights.isEmpty)
    }

    func testTheFontSizeSurvivesTheBoundaryAsANumber() {
        // The one payload field that is not a string. A host that decoded it as text would
        // silently leave the size alone, which is the kind of bug that only shows on the
        // platform whose bridge is weakest.
        _ = session.showStartPage()
        _ = session.navigationFinished(url: nil, generator: "WebReader Start")

        _ = session.message("readerSettings", body: .object(["fontSize": .number(22)]))

        XCTAssertEqual(ReaderStore.settings(store: store).fontSize, 22)
    }

    func testAManualToggleOnANonArticleStillRejects() {
        // The beep is the only answer this path has, and the toggle is enabled for any web
        // page: a page that does not extract otherwise changes nothing and says nothing.
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")
        XCTAssertEqual(session.extractionResult(url: page, result: nil, title: nil), [])

        guard case .extract? = session.toggleReader(currentURL: page).first else {
            return XCTFail("the toggle must ask for an extraction")
        }
        XCTAssertEqual(session.extractionResult(url: page, result: nil, title: nil), [.reject])
    }

    func testASiteCannotClaimToBeOneOfOurPages() {
        // Our own documents carry no URL of their own, so a page that has one and says it was
        // generated by the start page is a site asking for that page's handlers —
        // `readerClear` among them, which tombstones recents on every other device.
        var history = ReaderHistory()
        history.record(title: "Kept", url: "https://example.test/kept", at: 100)
        ReaderStore.setHistory(history, store: store)
        _ = session.openIncoming(page)

        let commands = session.navigationFinished(url: page, generator: "WebReader Start")

        guard case .extract? = commands.first else {
            return XCTFail("a real page must be offered to the reader, got \(commands)")
        }
        XCTAssertEqual(session.message("readerClear", body: .text("")), [])
        XCTAssertEqual(ReaderStore.history(store: store).entries.map(\.title), ["Kept"])
    }

    func testARankingThatLandsLateIsNotHandedToWhateverIsOnScreen() {
        // The rows are ranked against everything this device has read, and they are pushed by
        // evaluating a script by name — which a site is free to define.
        let items = [FeedItem(title: "Suggested", url: "https://example.test/suggested",
                              source: "example.test")]
        _ = session.showStartPage()
        _ = session.navigationFinished(url: nil, generator: "WebReader Start")
        XCTAssertFalse(session.showSuggestions(items).isEmpty)

        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")

        XCTAssertEqual(session.showSuggestions(items), [])
    }

    func testAFeedLookupThatLandsAfterTheSettingsPageSaysNothing() {
        // Both answers are inline messages for a form that is no longer there; the failure is
        // the likely one, since a site address that resolves to no feed is the common miss.
        _ = session.showSettingsPage()
        _ = session.navigationFinished(url: nil, generator: "WebReader Settings")
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")

        let source = FeedSource(url: "https://example.test/feed", title: "Feed", language: nil)
        XCTAssertEqual(session.sourceResolved(source), [])
        XCTAssertEqual(session.sourceResolved(nil), [])
        XCTAssertFalse(ReaderStore.suggestions(store: store).sources.contains(source))
    }

    func testAFeedAddressIsNotOfferedToTheReader() {
        // Two engines, two ways in: WebKit refuses the response and reports 100, Chromium
        // renders its own XML view and the extraction script recognises it. Both have to end
        // on a page with a way out, because neither leaves a site behind to fall back to.
        _ = session.openIncoming(page)
        _ = session.navigationFinished(url: page, generator: "")

        let byScript = session.extractionResult(url: page, result: Reader.notAPageSentinel,
                                                title: "Kort nyt | DR")
        guard case let .show(html, baseURL)? = byScript.first else {
            return XCTFail("a file has to be answered with our own page, got \(byScript)")
        }
        XCTAssertNil(baseURL)
        XCTAssertTrue(html.contains("nothing to read here"))
        XCTAssertFalse(html.contains("Try Again"))
        XCTAssertTrue(session.isShowingFallback)
        // Nothing was filed under the address, and the reader was not entered.
        XCTAssertTrue(ReaderStore.history(store: store).entries.isEmpty)
        XCTAssertFalse(session.isShowingReader)
        // Home works from here, which is the whole point of not leaving the file on screen.
        XCTAssertFalse(session.message("readerHome", body: .text("")).isEmpty)

        let byResponse = session.loadFailed(url: page, code: 100)
        guard case let .show(failureHTML, _)? = byResponse.first else {
            return XCTFail("code 100 has to render the same page, got \(byResponse)")
        }
        XCTAssertTrue(failureHTML.contains("nothing to read here"))
    }

    func testBackFromAnArticleDoesNotReturnToTheSameArticle() {
        // The whole of #42: the web view's history is [start page, the site, the reader
        // render], so its own Back lands on the site, which is offered to Readability exactly
        // as any page is and renders the same article again.
        _ = session.showStartPage()
        _ = session.openIncoming(page)
        _ = session.extractionResult(url: page, result: extracted, title: nil)
        XCTAssertTrue(session.canGoBack)

        let commands = session.back()

        guard case let .show(html, baseURL)? = commands.first else {
            return XCTFail("back has to render the page before the article, got \(commands)")
        }
        XCTAssertNil(baseURL, "the start page is one of ours, so it has no base URL")
        XCTAssertTrue(html.contains("Paste or type a URL"))
        // And nothing of the reader is left claiming the screen.
        XCTAssertFalse(session.isShowingReader)
    }

    func testBackFromAnArticleReachesTheArticleBeforeIt() {
        // "The last article, or home" — so a second article goes back to the first, from the
        // saved copy rather than by fetching and extracting it again.
        let second = URL(string: "https://example.test/second")!
        let secondArticle = Article(title: "The second one", byline: nil, siteName: nil,
                                    content: "<p>More</p>")
        _ = session.showStartPage()
        _ = session.openIncoming(page)
        _ = session.extractionResult(url: page, result: extracted, title: nil)
        _ = session.openIncoming(second)
        _ = session.extractionResult(url: second,
                                     result: String(decoding: try! JSONEncoder().encode(secondArticle),
                                                    as: UTF8.self),
                                     title: nil)

        guard case let .show(html, baseURL)? = session.back().first else {
            return XCTFail("back has to render the previous article")
        }
        XCTAssertEqual(baseURL, page, "the reader renders with the article as its base")
        // The body, not the title: the reader page's own recents popover lists both articles,
        // so a title tells you nothing about which one is rendered.
        XCTAssertTrue(html.contains(article.content))
        XCTAssertFalse(html.contains(secondArticle.content))

        // Once more reaches the start page, and then there is nothing of ours left: the host
        // is free to fall through to its own history, or to leave.
        guard case let .show(startHTML, _)? = session.back().first else {
            return XCTFail("back has to reach the start page")
        }
        XCTAssertTrue(startHTML.contains("Paste or type a URL"))
        XCTAssertFalse(session.canGoBack)
        XCTAssertEqual(session.back(), [])
    }

    func testBackFromAFileLeavesTheFallbackRatherThanGoingPastIt() {
        // A fallback page is not somewhere anyone navigated to, so it is not a step of its own.
        _ = session.showStartPage()
        _ = session.openIncoming(page)
        _ = session.extractionResult(url: page, result: Reader.notAPageSentinel, title: nil)
        XCTAssertTrue(session.isShowingFallback)

        guard case let .show(html, _)? = session.back().first else {
            return XCTFail("back has to leave the fallback")
        }
        XCTAssertTrue(html.contains("Paste or type a URL"))
        XCTAssertFalse(session.isShowingFallback)
    }

    func testAFeedIsOfferedAsASourceRatherThanADeadEnd() {
        // #43: a reader handed a feed was handed a list of articles it knows what to do with.
        // The page goes up first, then the address is looked up through the same command the
        // settings page's form uses — the host cannot tell the two apart, and need not.
        _ = session.showStartPage()
        _ = session.openIncoming(page)
        let commands = session.extractionResult(url: page, result: Reader.notAPageSentinel,
                                                title: nil)
        XCTAssertEqual(commands.count, 2)
        guard case .show? = commands.first, case let .resolveSource(asked)? = commands.last else {
            return XCTFail("the page and a lookup, got \(commands)")
        }
        XCTAssertEqual(asked, page)

        // Nothing is stored yet: opening a link is not asking to subscribe to it.
        let feed = FeedSource(url: page.absoluteString, title: "Kort nyt | DR", language: "da")
        let offer = session.sourceResolved(feed)
        XCTAssertFalse(ReaderStore.suggestions(store: store).sources.contains(feed))
        guard case let .evaluate(script)? = offer.first else {
            return XCTFail("the page has to be offered the feed, got \(offer)")
        }
        XCTAssertTrue(script.contains("readerOfferFeed"))
        XCTAssertTrue(script.contains("Kort nyt"))

        // Accepting adds it and leaves for the start page, where its articles will turn up.
        let accepted = session.message("readerAddSource", body: .text(page.absoluteString))
        XCTAssertTrue(ReaderStore.suggestions(store: store).sources.contains(feed))
        guard case let .show(html, _)? = accepted.first else {
            return XCTFail("accepting has to go somewhere, got \(accepted)")
        }
        XCTAssertTrue(html.contains("Paste or type a URL"))
    }

    func testAPageCannotTalkTheOfferIntoAddingSomethingElse() {
        // The offer is matched against what was actually looked up, so the fallback page's
        // widened gate cannot be used to add an address nobody opened.
        _ = session.openIncoming(page)
        _ = session.extractionResult(url: page, result: Reader.notAPageSentinel, title: nil)
        _ = session.sourceResolved(FeedSource(url: page.absoluteString, title: "Feed",
                                              language: nil))

        let sneaky = session.message("readerAddSource",
                                     body: .text("https://elsewhere.test/feed"))

        XCTAssertTrue(ReaderStore.suggestions(store: store).sources
            .allSatisfy { $0.url != "https://elsewhere.test/feed" })
        // It falls through to the settings-page rule, which refuses it: that page isn't up.
        XCTAssertEqual(sneaky.count, 1)
        guard case let .evaluate(script)? = sneaky.first else { return XCTFail("expected a reply") }
        XCTAssertTrue(script.contains("readerSourceRejected"))
    }

    func testBackFromOurOwnPageMeansLeaveRatherThanTheWebViewsHistory() {
        // Found by pressing Back twice on a phone: the web view's history still holds the
        // article and the site behind it, so consulting it from the start page resurrected
        // the article the reader had just left — the same complaint as #42, one step later.
        _ = session.showStartPage()
        XCTAssertFalse(session.canGoBack)
        XCTAssertEqual(session.backFallback, .leave)

        // In the reader, with nothing before it, the answer is the same: our page is showing.
        _ = session.openIncoming(page)
        _ = session.extractionResult(url: page, result: extracted, title: nil)
        _ = session.navigationFinished(url: page, generator: "WebReader")
        XCTAssertEqual(session.backFallback, .leave)

        // Someone else's page is the one case where its own history is right: a site's links
        // are its own to walk.
        let site = URL(string: "https://example.test/not-an-article")!
        _ = session.openIncoming(site)
        // The navigation start matters: it is what tells the session the reader's rendering is
        // no longer what is on screen, and every host reports it.
        session.navigationStarted()
        _ = session.navigationFinished(url: site, generator: "")
        _ = session.extractionResult(url: site, result: nil, title: nil)
        XCTAssertEqual(session.backFallback, .webViewHistory)
    }
}

final class ReaderOffPerSiteTests: XCTestCase {
    private var store: MemoryStore!
    private var session: ReaderSession!
    private let article = URL(string: "https://www.example.test/news/paywalled")!

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        session = ReaderSession(store: store,
                                cache: ArticleCache(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("ReaderOff-\(UUID().uuidString)")),
                                appName: "WebReader", platform: .iOS)
    }

    /// Turning the reader off has to *go and get* the site: what is on screen when the menu
    /// item is pressed is an extracted copy, and no copy has a login form in it.
    func testTurningItOffLoadsTheSiteItself() {
        _ = session.openIncoming(article)
        _ = session.navigationFinished(url: article, generator: "")
        _ = session.extractionResult(url: article, result: Self.extracted, title: nil)
        // The render is a load of its own; the reader is up when that lands, not when the
        // extraction returns.
        _ = session.navigationFinished(url: article, generator: "WebReader Page")
        XCTAssertTrue(session.isShowingReader)

        let commands = session.message("readerOriginal", body: .text(""))
        XCTAssertEqual(commands, [.load(article)])
        XCTAssertFalse(session.isShowingReader)
        // Keyed by host, not by article: signing in takes several of the site's pages.
        XCTAssertEqual(ReaderStore.settings(store: store).originalHosts, ["example.test"])
    }

    /// And the next page from that host is left alone, with our own way back on it.
    func testAnExcludedHostIsLeftAloneAndKeepsAWayBack() {
        var settings = ReaderStore.settings(store: store)
        settings.originalHosts = ["example.test"]
        ReaderStore.setSettings(settings, store: store)

        let login = URL(string: "https://www.example.test/account/login")!
        let commands = session.navigationFinished(url: login, generator: "")
        guard case let .evaluate(script)? = commands.first else {
            return XCTFail("the site was extracted anyway: \(commands)")
        }
        XCTAssertFalse(commands.contains { if case .extract = $0 { return true } else { return false } })
        XCTAssertTrue(script.contains("Read this page"))
        XCTAssertTrue(script.contains("readerOriginal"))
        // A closed shadow root, so the site's own CSS cannot hide the way out.
        XCTAssertTrue(script.contains("attachShadow"))
        // Injected on every load of that host, so it must not stack.
        XCTAssertTrue(script.contains("if (document.getElementById('__readerGuest')) { return; }"))
    }

    /// Pressing it again reads the page that is already on screen, and stops excluding the
    /// host — the login it was turned off for has happened by then.
    func testTurningItBackOnReadsThePageThatIsUp() {
        var settings = ReaderStore.settings(store: store)
        settings.originalHosts = ["example.test"]
        ReaderStore.setSettings(settings, store: store)
        _ = session.navigationFinished(url: article, generator: "")

        let commands = session.message("readerOriginal", body: .text(""))
        XCTAssertTrue(commands.contains { if case .extract = $0 { return true } else { return false } },
                      "expected the page on screen to be read, got \(commands)")
        XCTAssertTrue(ReaderStore.settings(store: store).originalHosts.isEmpty)
    }

    /// The list travels with the other settings, or signing in on one device leaves the
    /// others extracting the paywall notice.
    func testTheListSyncsWithTheRestOfTheSettings() {
        var settings = ReaderSettings()
        settings.originalHosts = ["example.test", "other.test"]
        let decoded = ReaderSettings.fromJSON(settings.json)
        XCTAssertEqual(decoded.originalHosts, ["example.test", "other.test"])
        // Sorted on the way out: two devices holding the same set must write equal bytes,
        // or the folder is rewritten forever.
        XCTAssertTrue(settings.json.contains("\"example.test\",\"other.test\"")
                      || settings.json.contains("\"example.test\", \"other.test\""),
                      settings.json)
    }

    /// A site must not be able to opt itself out of being read.
    ///
    /// Android's `addJavascriptInterface` bridge is attached to the web view, so every page
    /// loaded in it can call `postMessage` — including a publisher's own. Turning the reader
    /// off is durable and syncs, so a page that could ask for it would be disabling the
    /// reader for that domain on every device the user owns. Every other handler was already
    /// gated on one of our pages showing; this one was not.
    func testASiteCannotTurnTheReaderOffForItself() {
        let article = URL(string: "https://www.example.test/news/paywalled")!
        _ = session.openIncoming(article)
        _ = session.navigationFinished(url: article, generator: "")
        // A site is on screen, so nothing here is one of our pages.
        let commands = session.message("readerOriginal", body: .text(""))
        XCTAssertEqual(commands, [])
        XCTAssertTrue(ReaderStore.settings(store: store).originalHosts.isEmpty,
                      "a page we did not write disabled the reader for its own host")
    }

    /// The injected chrome's direction stays open, because it cannot be abused: the worst a
    /// hostile page achieves by pressing its own "Read this page" is being read.
    func testASiteCanOnlyEverTurnItBackOn() {
        var settings = ReaderStore.settings(store: store)
        settings.originalHosts = ["example.test"]
        ReaderStore.setSettings(settings, store: store)
        let article = URL(string: "https://www.example.test/news/paywalled")!
        _ = session.navigationFinished(url: article, generator: "")

        let commands = session.message("readerOriginal", body: .text(""))
        XCTAssertTrue(commands.contains { if case .extract = $0 { return true } else { return false } })
        XCTAssertTrue(ReaderStore.settings(store: store).originalHosts.isEmpty)
    }

    private static let extracted =
        #"{"title":"Paywalled","content":"<p>Half of it.</p>","byline":null,"#
        + #""siteName":null,"image":null,"hidden":{}}"#
}
