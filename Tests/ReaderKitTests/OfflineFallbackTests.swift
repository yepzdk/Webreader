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
        XCTAssertTrue(html.contains("readerPost('readerHome'"))
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

    func testAFeedAddressIsAnsweredWithAWayOutRatherThanNothing() {
        // Pasting a feed address into "Open URL from Clipboard" used to leave the window on a
        // page with none of our chrome and no way back, because WebKit cancels a response it
        // cannot show with code 102 — which `isIgnorable` swallows, since our own policy
        // cancellations raise the same one. 100 is WebKit's code for this case specifically.
        XCTAssertEqual(OfflineFallback.classify(errorCode: 100), .notAPage)
        XCTAssertFalse(OfflineFallback.isIgnorable(errorCode: 100))

        let page = OfflineFallback.html(appName: "WebReader", host: "www.dr.dk", kind: .notAPage)
        XCTAssertTrue(page.contains("nothing to read here"))
        XCTAssertTrue(page.contains("www.dr.dk"))
        // Home is the way out, and it comes from the same chrome every generated page carries.
        XCTAssertTrue(page.contains("readerHome"))
        // No Try Again: the address will answer with the same file next time, and a button
        // certain to fail is worse than no button.
        XCTAssertFalse(page.contains("Try Again"))
        XCTAssertFalse(OfflineFallback.Kind.notAPage.retryable)

        // Every kind that describes a failure still offers it.
        for kind in [OfflineFallback.Kind.offline, .cannotReach, .timedOut, .generic] {
            XCTAssertTrue(kind.retryable, "\(kind)")
            XCTAssertTrue(OfflineFallback.html(appName: "WebReader", host: "x.test", kind: kind)
                .contains("Try Again"), "\(kind)")
        }
    }
}

final class OfflineFallbackFeedOfferTests: XCTestCase {
    private func notAPage() -> String {
        OfflineFallback.html(appName: "WebReader", host: "www.dr.dk", kind: .notAPage)
    }

    /// The page with every script's contents dropped, which is what the window shows before
    /// anything runs — and, since the offer may never be made, possibly forever.
    private func visibleContent(of page: String) -> String {
        var shown = ""
        var rest = Substring(page)
        while let open = rest.range(of: "<script>") {
            shown += rest[..<open.lowerBound]
            guard let close = rest.range(of: "</script>", options: [],
                                        range: open.upperBound..<rest.endIndex) else { break }
            rest = rest[close.upperBound...]
        }
        return shown + rest
    }

    func testTheOfferIsShippedHiddenBecauseItMayNeverBeMade() {
        // Confirming the address is a feed means fetching and parsing it, and it may turn out
        // to be a PDF instead — so the page has to read correctly with the offer never made.
        let page = notAPage()
        XCTAssertTrue(page.contains("<button id=\"readerFeedOffer\" hidden></button>"))
        // The label exists only as the script's template. Nothing of the offer reaches the
        // rendered content, so there is no visible dead control and no empty box: the button
        // ships hidden and empty, and `hidden` is the whole of its styling.
        let shown = visibleContent(of: page)
        XCTAssertFalse(shown.contains("Add “"))
        XCTAssertFalse(shown.contains("to suggested articles"))
        XCTAssertFalse(shown.contains("readerOfferFeed"))
        // The card is unchanged otherwise: still no Try Again, still the file-x icon.
        XCTAssertFalse(shown.contains("Try Again"))
        XCTAssertTrue(shown.contains("There&#39;s nothing to read here"))
    }

    func testTheOfferRevealsItselfAndPostsAddSource() {
        let page = notAPage()
        XCTAssertTrue(page.contains("window.readerOfferFeed = function"))
        XCTAssertTrue(page.contains("readerPost('readerAddSource', offer.dataset.url)"))
        XCTAssertTrue(page.contains("offer.hidden = false;"))
        // The label is the feed's own title in typographic quotes, built from text.
        XCTAssertTrue(page.contains("'Add “' + feed.title + '” to suggested articles'"))
    }

    func testTheOfferWearsThePagesOwnButtonStyling() {
        // No new colours and no class of its own: `.card button` is the primary action, and
        // the offer is this page's primary action.
        let page = notAPage()
        XCTAssertTrue(page.contains(".card button {"))
        XCTAssertFalse(page.contains("class=\"feed-offer\""))
        XCTAssertFalse(page.contains("#readerFeedOffer {"))
    }

    func testAFeedTitleCannotInjectMarkup() {
        // The title comes from a stranger's feed, so it reaches the DOM through
        // `textContent` — the label is never assembled as markup. A title carrying a script
        // payload is therefore inert no matter what the host passes, and the page's own
        // bytes never contain it: the offer arrives later, over `evaluate`.
        let page = notAPage()
        let hostile = "<img src=x onerror=alert(1)> \"quoted\" and “curly”"
        XCTAssertFalse(page.contains(hostile))
        XCTAssertFalse(page.contains("onerror"))
        XCTAssertFalse(page.contains("<img"))
        // The one path the title can take is assignment to `textContent`, which parses no
        // markup; nothing on the page writes it into `innerHTML` or `insertAdjacentHTML`.
        XCTAssertTrue(page.contains("offer.textContent = 'Add “'"))
        XCTAssertFalse(page.contains("innerHTML"))
        XCTAssertFalse(page.contains("insertAdjacentHTML"))
        // Were the title ever routed through a script literal instead, this is the escaping
        // it would have to survive — the same rule the suggestion titles already follow.
        XCTAssertFalse(HTML.jsString(hostile).contains("</"))
    }

    func testASecondOfferRelabelsRatherThanStacking() {
        let page = notAPage()
        // There is one button and the script never makes another, so a second offer can only
        // relabel the one that is already there.
        XCTAssertEqual(page.components(separatedBy: "id=\"readerFeedOffer\"").count - 1, 1)
        XCTAssertFalse(page.contains("createElement"))
        XCTAssertFalse(page.contains("appendChild"))
        // A payload missing either field is dropped, so a half-written offer is unreachable.
        XCTAssertTrue(page.contains("if (!feed || !feed.title || !feed.url) { return; }"))
    }

    func testOnlyTheFeedKindCarriesTheOffer() {
        // Nothing else the reader refuses to display is a feed: the other four kinds mean the
        // address never answered at all, so offering to subscribe to it would be nonsense.
        for kind in [OfflineFallback.Kind.offline, .cannotReach, .timedOut, .generic] {
            let page = OfflineFallback.html(appName: "WebReader", host: "x.test", kind: kind)
            XCTAssertFalse(page.contains("readerOfferFeed"), "\(kind)")
            XCTAssertFalse(page.contains("readerFeedOffer"), "\(kind)")
            XCTAssertFalse(page.contains("readerAddSource"), "\(kind)")
        }
    }
}
