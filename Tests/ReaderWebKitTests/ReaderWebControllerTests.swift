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

    // MARK: - Driving the page

    private func click(_ selector: String, file: StaticString = #filePath, line: UInt = #line) {
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

    /// Waits for the document on screen to be the generated page with this marker. The marker
    /// is what a restored page identifies itself by, so asserting on it is asserting on the
    /// same fact the controller uses.
    private func waitForGenerator(_ generator: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        waitFor("the \(generator) page", file: file, line: line) {
            var found = false
            let done = self.expectation(description: "generator")
            self.controller.webView.evaluateJavaScript(ReaderSession.generatorScript) { result, _ in
                found = (result as? String) == generator
                done.fulfill()
            }
            self.wait(for: [done], timeout: 5)
            return found
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10,
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
