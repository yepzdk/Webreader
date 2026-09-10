import XCTest
import WebKit
@testable import ReaderKit
@testable import ReaderWebKit

/// The host contract, driven through a real `WKWebView` and the real generated pages.
///
/// These exist because the controller is the one part of the reader that unit tests could
/// never reach while it lived in `AppDelegate` — and it is about to have a second and third
/// caller (iOS, then Android's Kotlin equivalent). What they defend is the *wiring*: a
/// message name that was never registered, a gate that closed on the wrong page, a service
/// the shell forgot to answer. Each one clicks a control the user clicks, on the page the
/// user sees, and asserts the state the app persists.
///
/// Nothing here needs a window: `WKWebView` loads, runs scripts and delivers messages
/// perfectly well off screen, which is what makes this runnable in CI.
final class ReaderWebControllerTests: XCTestCase {
    private var directory: URL!
    private var store: FileStore!
    private var services: StubServices!
    private var controller: ReaderWebController!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderWebKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = FileStore(fileURL: directory.appendingPathComponent("store.json"))
        // No sources, so the start page's best-effort suggestion fetch never reaches the
        // network: these tests must not depend on wallnot.dk being up.
        ReaderStore.setSuggestions(SuggestionSettings(sources: []), store: store)
        services = StubServices()
        controller = ReaderWebController(
            store: store,
            cache: ArticleCache(directory: directory.appendingPathComponent("articles")),
            appName: "WebReader",
            platform: .macOS,
            userAgentApplicationName: "Version/26.0 Safari/605.1.15",
            services: services)
    }

    override func tearDown() {
        controller = nil
        services = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The start page comes up as one of ours. Until this is true nothing else can be:
    /// every message handler is gated on the page state this establishes.
    func testStartPageLoadsAsAnOwnPage() {
        controller.showStartPage()
        waitForGenerator("WebReader Start")
        XCTAssertTrue(controller.session.pageState.isShowingStartPage)
        XCTAssertTrue(controller.session.pageState.isOwnPage)
    }

    /// Clear history, clicked on the start page, reaches the store as a tombstone rather than
    /// an empty list — the distinction the whole sync merge rests on.
    func testClearHistoryFromTheStartPageWritesATombstone() {
        var history = ReaderHistory()
        history.record(title: "An article", url: "https://example.com/a", image: nil)
        ReaderStore.setHistory(history, store: store)

        controller.showStartPage()
        waitForGenerator("WebReader Start")
        click("#startClear")

        waitFor("the history to be cleared") {
            ReaderStore.history(store: self.store).entries.isEmpty
        }
        XCTAssertNotNil(ReaderStore.history(store: store).clearedAt,
                        "a cleared list must carry the timestamp that beats a stale peer")
    }

    /// The settings button posts `readerOpenSettings`, and the controller answers by loading
    /// the settings page — which proves the gate (`isShowingStartPage`) and the page swap.
    func testSettingsButtonOpensTheSettingsPage() {
        controller.showStartPage()
        waitForGenerator("WebReader Start")
        click("#startSettings")
        waitForGenerator("WebReader Settings")
        XCTAssertTrue(controller.session.pageState.isShowingSettings)
    }

    /// A URL the app cannot open is refused twice over: the shell is asked to signal it (a
    /// beep on a Mac, a haptic on a phone) and the page is told to say so. The shell half is
    /// the seam this refactor introduced, so it is the half worth pinning.
    func testRejectedURLAsksTheShellToSignalIt() {
        controller.showStartPage()
        waitForGenerator("WebReader Start")
        waitFor("the URL field to be ready") { self.probe("!!document.querySelector('#open')") }
        evaluate("document.querySelector('#url').value = 'not a url at all';"
            + "document.querySelector('#open').requestSubmit();")

        waitFor("the shell to be asked to reject") { self.services.rejections == 1 }
        XCTAssertTrue(controller.session.pageState.isShowingStartPage,
                      "a refusal must leave the page it was typed on standing")
    }

    /// A live site must never reach a handler. The gate is the page state, so a page that is
    /// not one of ours leaves every message unanswered.
    func testMessagesFromAForeignPageAreIgnored() {
        // `loadHTMLString` with no page state set: exactly what a site's document looks like
        // to the gates, without the network.
        controller.webView.loadHTMLString(
            "<html><body>a site</body></html>", baseURL: URL(string: "https://example.com"))
        waitFor("the foreign page to finish") {
            self.controller.session.pageState.page == .none && !self.controller.webView.isLoading
        }
        var history = ReaderHistory()
        history.record(title: "An article", url: "https://example.com/a", image: nil)
        ReaderStore.setHistory(history, store: store)

        evaluate("window.webkit.messageHandlers.readerClear.postMessage('')")
        // A negative is only ever "not yet", so give the message every chance to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(ReaderStore.history(store: store).entries.count, 1,
                       "a page that isn't ours must not be able to clear the reader's history")
    }

    /// The cover comes down when our document is on screen, not when it is handed to the web
    /// view. Hiding it at the hand-off showed a frame or two of the page being replaced —
    /// the flash the cover exists to prevent.
    func testTheCoverStaysUpUntilOurOwnPageHasLoaded() {
        let cover = SpyCover()
        controller.loadingCover = cover
        cover.show(theme: .auto)

        controller.showStartPage()
        XCTAssertTrue(cover.isUp, "the cover came down as the document was handed over")

        waitForGenerator("WebReader Start")
        waitFor("the cover to come down") { !cover.isUp }
    }

    /// A site is covered from the moment the load is issued. WebKit reports a navigation
    /// started some time after being asked to start it, and everything in between was the
    /// page being left, uncovered.
    func testASiteIsCoveredAsSoonAsTheLoadIsIssued() {
        controller.showStartPage()
        waitForGenerator("WebReader Start")
        let cover = SpyCover()
        controller.loadingCover = cover

        // A port nothing is listening on: the load is issued and fails, which is all this
        // needs — the assertion is about the same turn of the run loop, before any callback.
        XCTAssertTrue(controller.openIncoming(URL(string: "http://127.0.0.1:9/x")!))
        XCTAssertTrue(cover.isUp, "the site was uncovered between the load and its first callback")
    }

    /// A load that commits and then goes silent has to be given an ending. Nothing else will
    /// end it: no finish, no failure, so the app would sit behind the cover for as long as it
    /// was open — which is what shipped, and what the cover must never be allowed to become.
    ///
    /// The old answer was to reveal the site on a timer, and that is the flash: a news page
    /// paints its masthead in the first second and then sits still while its trackers finish,
    /// so the timer fired with the raw site on screen and extraction still to come.
    func testALoadThatGoesSilentEndsWithAWayOut() throws {
        let server = try XCTUnwrap(SilentServer(), "could not listen on the loopback interface")
        defer { server.stop() }
        let cover = SpyCover()
        controller.loadingCover = cover
        controller.stallPatience = 0.6

        XCTAssertTrue(controller.openIncoming(URL(string: "http://127.0.0.1:\(server.port)/")!))
        XCTAssertTrue(cover.isUp)
        // No reveal on the way: the only thing that may take the cover down is the answer.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(cover.isUp, "the site was revealed on a timer")

        waitFor("the load to be called over") { self.controller.session.isShowingFallback }
        // The offline page is a page: it comes down when *it* has loaded, which is the same
        // rule as everywhere else.
        waitFor("the cover to come down") { !cover.isUp }
        // `textContent`, not `innerText`: this web view has no frame, so nothing is laid
        // out and `innerText` is empty whether the words are there or not.
        XCTAssertTrue(probe("document.body.textContent.includes('timed out')"),
                      "reported as something other than the timeout it is")
        XCTAssertTrue(probe("document.body.textContent.includes('Try Again')"),
                      "an ending with no way out of it")
    }

    // MARK: - Driving the page

    /// Clicks a control the user clicks, once the page is ready to answer.
    private func click(_ selector: String, file: StaticString = #filePath, line: UInt = #line) {
        // The element has to exist *and* its listener has to be attached. Both are covered by
        // waiting for it to be in the document once `readyState` is `complete`, since the
        // page's handlers are attached by an inline script.
        waitFor("\(selector) to be clickable", file: file, line: line) {
            self.probe("!!document.querySelector('\(selector)')", file: file, line: line)
        }
        evaluate("document.querySelector('\(selector)').click()", file: file, line: line)
    }

    /// Runs `script` in the page. Wrapped so the result is always something WebKit can bridge
    /// back — a bare `postMessage(…)` evaluates to `undefined`, which comes back as an error
    /// about an unsupported type rather than as success.
    private func evaluate(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "evaluate \(script)")
        controller.webView.evaluateJavaScript("(function(){ \(script)\nreturn true })()") { _, error in
            if let error { XCTFail("\(script): \(error)", file: file, line: line) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// Evaluates a boolean expression in the page, treating any error as false — a page that
    /// is still loading answers "not yet" rather than failing the test.
    private func probe(_ expression: String,
                       file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var value = false
        let done = expectation(description: "probe \(expression)")
        controller.webView.evaluateJavaScript("(function(){ return !!(\(expression)) })()") { result, _ in
            value = (result as? Bool) ?? false
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return value
    }

    /// Waits until the page on screen is the generated one with this marker *and* has finished
    /// loading.
    ///
    /// The marker alone is not enough, and that is what made this suite flaky on a loaded CI
    /// machine: `<meta name="generator">` is in `<head>`, so it answers long before the inline
    /// script at the end of the body has attached the click handlers a test then clicks. On a
    /// fast machine the gap is microseconds; on a slow one the click lands on a page that is
    /// not listening yet and nothing happens.
    private func waitForGenerator(_ generator: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        waitFor("the \(generator) page", file: file, line: line) {
            self.probe("document.readyState === 'complete' && "
                + "((document.querySelector('meta[name=\"generator\"]')||{}).content === '\(generator)')",
                file: file, line: line)
        }
    }

    // 20 seconds, not 5: these wait on a real WebKit process, and a CI machine running several
    // jobs at once is slow enough that a tighter bound tests the runner rather than the code.
    private func waitFor(_ what: String, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line,
                         until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

/// The shell, reduced to counters. Every method here is one of the four things WebKit cannot
/// answer for itself.
private final class StubServices: ReaderHostServices {
    private(set) var rejections = 0
    private(set) var externalOpens: [URL] = []
    private(set) var syncSetupRequests = 0

    func reject() { rejections += 1 }
    func openExternally(_ url: URL) { externalOpens.append(url) }
    func bringToFront() {}
    func presentSyncSetup() { syncSetupRequests += 1 }
}

/// The cover, reduced to whether it is up.
private final class SpyCover: ReaderLoadingCover {
    private(set) var isUp = false

    func show(theme: ReaderSettings.Theme) { isUp = true }
    func hide() { isUp = false }
}

/// A socket that accepts a connection and then says nothing at all.
///
/// The shape of the load this exists to test: committed, silent, and never failing. No
/// network and no service — a listener on the loopback interface, bound to whatever port the
/// kernel hands out, holding every connection open until the test is over.
final class SilentServer {
    private let socketFD: Int32
    private var accepted: [Int32] = []
    private let lock = NSLock()
    let port: UInt16

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0  // the kernel picks
        let bound = withUnsafePointer(to: &address) {
            bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            getsockname(fd, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                        &length)
        }
        guard named == 0 else { close(fd); return nil }
        socketFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        // Every member is set: the accept loop can have the object now.
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else { return }
                // Held, not answered, and not closed: closing would be an ending.
                self.lock.lock()
                self.accepted.append(client)
                self.lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        for client in accepted { close(client) }
        accepted = []
        lock.unlock()
        close(socketFD)
    }
}
