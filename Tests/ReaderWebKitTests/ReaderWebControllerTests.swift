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
        XCTAssertTrue(controller.pageState.isShowingStartPage)
        XCTAssertTrue(controller.pageState.isOwnPage)
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
        XCTAssertTrue(controller.pageState.isShowingSettings)
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
        XCTAssertTrue(controller.pageState.isShowingStartPage,
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
            self.controller.pageState.page == .none && !self.controller.webView.isLoading
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
