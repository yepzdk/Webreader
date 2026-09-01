import XCTest
@testable import ReaderKit

// Tests for the pure offline-fallback logic: error classification and HTML generation.
// No WebKit/AppKit involved.

final class OfflineFallbackClassifyTests: XCTestCase {
    func testKnownCodesMapToKinds() {
        XCTAssertEqual(OfflineFallback.classify(errorCode: -1009), .offline)     // not connected
        XCTAssertEqual(OfflineFallback.classify(errorCode: -1001), .timedOut)    // timed out
        XCTAssertEqual(OfflineFallback.classify(errorCode: -1003), .cannotReach) // cannot find host
        XCTAssertEqual(OfflineFallback.classify(errorCode: -1006), .cannotReach) // DNS lookup failed
    }

    func testUnknownCodeIsGeneric() {
        XCTAssertEqual(OfflineFallback.classify(errorCode: -1200), .generic)
        XCTAssertEqual(OfflineFallback.classify(errorCode: 42), .generic)
    }

    func testIgnorableCodes() {
        XCTAssertTrue(OfflineFallback.isIgnorable(errorCode: -999)) // cancelled
        XCTAssertTrue(OfflineFallback.isIgnorable(errorCode: 102))  // frame load interrupted by policy
        XCTAssertFalse(OfflineFallback.isIgnorable(errorCode: -1009))
        XCTAssertFalse(OfflineFallback.isIgnorable(errorCode: -1001))
    }
}

final class OfflineFallbackNavTests: XCTestCase {
    func testTheOfflinePageIsNotADeadEnd() {
        // Try Again retries the URL that just failed, so without this a failed load left no
        // route anywhere else (#15).
        let html = OfflineFallback.html(appName: "Reader", host: "x.test", kind: .offline)
        XCTAssertTrue(html.contains("id=\"readerHomeBtn\""))
        XCTAssertTrue(html.contains("messageHandlers.readerHome.postMessage"))
    }

    func testTheAccentButtonStylingStaysOnTheCard() {
        // The page styled every `button` as the primary action; the nav button must keep the
        // quiet chrome box it wears everywhere else.
        let html = OfflineFallback.html(appName: "Reader", host: "x.test", kind: .offline)
        XCTAssertTrue(html.contains(".card button {"))
        XCTAssertFalse(html.contains("\n          button {"))
    }
}

final class OfflineFallbackHTMLTests: XCTestCase {
    private func html(appName: String = "Example",
                      host: String? = "example.com",
                      kind: OfflineFallback.Kind = .offline) -> String {
        OfflineFallback.html(appName: appName, host: host, kind: kind)
    }

    func testContainsHeadlineAndRetryButton() {
        let page = html(kind: .offline)
        // The headline's apostrophe is HTML-escaped (You&#39;re).
        XCTAssertTrue(page.contains("You&#39;re offline"))
        XCTAssertTrue(page.contains("readerRetry"))
        XCTAssertTrue(page.contains("Try Again"))
    }

    func testGenericHeadlineUnescaped() {
        // A headline with no special chars passes through verbatim.
        XCTAssertTrue(html(kind: .timedOut).contains("The connection timed out"))
    }

    func testWeavesHostIntoReachabilityMessage() {
        XCTAssertTrue(html(host: "example.com", kind: .cannotReach).contains("“example.com”"))
    }

    func testFallsBackToGenericSiteWordWhenNoHost() {
        let page = html(host: nil, kind: .cannotReach)
        XCTAssertTrue(page.contains("the site"))
        XCTAssertFalse(page.contains("“”")) // no empty quotes
    }

    func testNeutralBackgroundWhenNoColor() {
        // The appearance-following variable (switches in dark mode), not a fixed color.
        XCTAssertTrue(html().contains("background: var(--bg);"))
    }

    func testNoEmojiInPage() {
        // Design convention: no emoji anywhere in the UI. Scan for any emoji-range scalar.
        let page = html()
        let hasEmoji = page.unicodeScalars.contains { scalar in
            (0x1F300...0x1FAFF).contains(scalar.value) || (0x2600...0x27BF).contains(scalar.value)
        }
        XCTAssertFalse(hasEmoji, "fallback page must not contain emoji")
    }

    // MARK: - JS interpolation

    func testJSLiteralNeutralizesScriptEndAndLineSeparators() {
        // Everything the app interpolates into a <script> comes from someone else's page:
        // feed titles, article titles, learned phrases.
        let json = "[\"</script><script>alert(1)</script>\",\"a\u{2028}b\u{2029}c\"]"
        let safe = HTML.jsLiteral(json)
        XCTAssertFalse(safe.lowercased().contains("</script"))
        // A raw U+2028/U+2029 ends a JS statement even inside a string literal.
        XCTAssertFalse(safe.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x2029 })
        XCTAssertTrue(safe.contains("\\u2028"))
        // Still the same JSON once the JS layer has read it back.
        XCTAssertEqual(safe.replacingOccurrences(of: "<\\/", with: "</")
            .replacingOccurrences(of: "\\u2028", with: "\u{2028}")
            .replacingOccurrences(of: "\\u2029", with: "\u{2029}"), json)
    }

    func testEscapesAppNameAndHost() {
        let page = OfflineFallback.html(appName: "A & <B>", host: "x\"y", kind: .cannotReach)
        XCTAssertTrue(page.contains("A &amp; &lt;B&gt;"))
        XCTAssertTrue(page.contains("x&quot;y"))
        XCTAssertFalse(page.contains("A & <B>"))
    }

    func testRespectsReducedMotionAndFocusVisible() {
        // Accessibility conventions: reduced-motion handling + a visible focus ring.
        let page = html()
        XCTAssertTrue(page.contains("prefers-reduced-motion"))
        XCTAssertTrue(page.contains(":focus-visible"))
    }
}
