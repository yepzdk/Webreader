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
}
