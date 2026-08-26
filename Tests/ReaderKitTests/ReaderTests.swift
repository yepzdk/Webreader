import XCTest
@testable import ReaderKit

// Tests for reader mode's pure core: decoding Readability's result, the reader page
// template, and the in-place replacement script. The live WebKit orchestration is
// hand-verified per repo convention.

final class ReaderDecodeTests: XCTestCase {
    func testDecodesFullArticle() {
        let json = """
        {"title":"A Title","byline":"By Someone","siteName":"The Site","content":"<p>Body</p>"}
        """
        XCTAssertEqual(Reader.decode(json),
                       Article(title: "A Title", byline: "By Someone",
                               siteName: "The Site", content: "<p>Body</p>"))
    }

    func testDecodesHiddenHitsAndDefaultsToEmpty() {
        let with = Reader.decode(#"{"title":"T","content":"<p>x</p>","hidden":{"annonce":2}}"#)
        XCTAssertEqual(with?.hiddenHits, ["annonce": 2])
        let without = Reader.decode(#"{"title":"T","content":"<p>x</p>"}"#)
        XCTAssertEqual(without?.hiddenHits, [:])
        let garbled = Reader.decode(#"{"title":"T","content":"<p>x</p>","hidden":"nope"}"#)
        XCTAssertEqual(garbled?.hiddenHits, [:])
    }

    func testEncodesAndDecodesItself() throws {
        // The cache stores articles with the encoder; hits ride along under the same key
        // the extraction script uses.
        let article = Article(title: "T", byline: nil, siteName: "S", content: "<p>x</p>",
                              hiddenHits: ["annonce": 2])
        let data = try JSONEncoder().encode(article)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"hidden\""))
        XCTAssertEqual(try JSONDecoder().decode(Article.self, from: data), article)
    }

    func testDecodesWithAbsentOptionals() {
        let article = Reader.decode(#"{"title":"T","content":"<p>x</p>"}"#)
        XCTAssertEqual(article?.title, "T")
        XCTAssertNil(article?.byline)
        XCTAssertNil(article?.siteName)
    }

    func testNilForNonArticleResults() {
        // The script returns null for non-readerable pages; WebKit may surface that
        // as nil or NSNull — and anything else unexpected must also decode to nil.
        XCTAssertNil(Reader.decode(nil))
        XCTAssertNil(Reader.decode(NSNull()))
        XCTAssertNil(Reader.decode(42))
        XCTAssertNil(Reader.decode(""))
        XCTAssertNil(Reader.decode("not json"))
        XCTAssertNil(Reader.decode(#"{"title":"missing content"}"#))
    }
}

final class ReaderSettingsTests: XCTestCase {
    func testDecodesFullPayload() {
        let payload: [String: Any] = ["fontSize": 21, "fontFamily": "sans", "width": "wide",
                                      "lineHeight": "relaxed", "theme": "sepia"]
        let settings = ReaderSettings.decode(payload)
        XCTAssertEqual(settings.fontSize, 21)
        XCTAssertEqual(settings.fontFamily, .sans)
        XCTAssertEqual(settings.width, .wide)
        XCTAssertEqual(settings.lineHeight, .relaxed)
        XCTAssertEqual(settings.theme, .sepia)
    }

    func testPartialAndUnknownFieldsFallBackToDefaults() {
        // A payload only naming some fields (or naming unknown values) keeps the
        // defaults for the rest — a garbled popover message can't poison the reader.
        let settings = ReaderSettings.decode(["theme": "black", "width": "ultrawide",
                                              "fontFamily": 7])
        XCTAssertEqual(settings.theme, .black)
        XCTAssertEqual(settings.width, .normal)
        XCTAssertEqual(settings.fontFamily, .serif)
        XCTAssertEqual(settings.fontSize, 17)
    }

    func testGarbageDecodesToDefaults() {
        XCTAssertEqual(ReaderSettings.decode(nil), ReaderSettings())
        XCTAssertEqual(ReaderSettings.decode("not a dict"), ReaderSettings())
        XCTAssertEqual(ReaderSettings.decode(NSNull()), ReaderSettings())
        XCTAssertEqual(ReaderSettings.fromJSON(nil), ReaderSettings())
        XCTAssertEqual(ReaderSettings.fromJSON("not json"), ReaderSettings())
    }

    func testQuoteStyleDecodesAndRoundTrips() {
        XCTAssertEqual(ReaderSettings.decode(["quoteStyle": "italic"]).quoteStyle, .italic)
        XCTAssertEqual(ReaderSettings.decode(["quoteStyle": "comic"]).quoteStyle, .bordered)
        var settings = ReaderSettings()
        settings.quoteStyle = .italic
        XCTAssertEqual(ReaderSettings.fromJSON(settings.json), settings)
    }

    func testFontSizeIsClamped() {
        XCTAssertEqual(ReaderSettings.decode(["fontSize": 6]).fontSize,
                       ReaderSettings.fontSizeRange.lowerBound)
        XCTAssertEqual(ReaderSettings.decode(["fontSize": 90]).fontSize,
                       ReaderSettings.fontSizeRange.upperBound)
    }

    func testJSONRoundTrip() {
        var settings = ReaderSettings()
        settings.fontSize = 14
        settings.fontFamily = .sans
        settings.width = .narrow
        settings.lineHeight = .compact
        settings.theme = .dark
        XCTAssertEqual(ReaderSettings.fromJSON(settings.json), settings)
    }
}

final class ReaderExtractionScriptTests: XCTestCase {
    func testContainsVendoredSourcesAndGate() {
        let script = Reader.extractionScript()
        // Both vendored libraries are inlined, and the cheap gate runs before parse.
        XCTAssertTrue(script.contains("function Readability("))
        XCTAssertTrue(script.contains("function isProbablyReaderable("))
        XCTAssertTrue(script.contains("isProbablyReaderable(document)"))
        // Parse must run on a clone — Readability's parse is destructive.
        XCTAssertTrue(script.contains("document.cloneNode(true)"))
    }

    func testStripsHiddenPhrasesFromParsedContent() {
        let script = Reader.extractionScript(hiding: HiddenPhrases(["Annonce", "</script>"]))
        XCTAssertTrue(script.contains("function readerHideBlocks("))
        // On a DOMParser document (no browsing context, so no image fetches), and the
        // filtered body is what gets returned.
        XCTAssertTrue(script.contains("new DOMParser().parseFromString(article.content"))
        XCTAssertTrue(script.contains("var hidden = readerHideBlocks(doc.body, [\"Annonce\",\"<\\/script>\"])"))
        XCTAssertTrue(script.contains("content: doc.body.innerHTML"))
        XCTAssertTrue(script.contains("hidden: hidden.hits"))
    }

    func testWrapsQuotationsAfterHiding() {
        let script = Reader.extractionScript()
        XCTAssertTrue(script.contains("function readerWrapQuotes("))
        // Hide first, then wrap — a removed block shouldn't be styled, and the wrap must
        // see the final DOM.
        let hide = script.range(of: "var hidden = readerHideBlocks(")!
        let wrap = script.range(of: "readerWrapQuotes(doc.body);")!
        XCTAssertTrue(hide.lowerBound < wrap.lowerBound)
    }
}

final class ReaderPageTests: XCTestCase {
    private let article = Article(title: "Tips & Tricks <2026>", byline: "By A & B",
                                  siteName: "News <Site>", content: "<p>Hello <em>world</em></p>")

    func testEscapesTitleAndMetaButNotContent() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("Tips &amp; Tricks &lt;2026&gt;"))
        XCTAssertTrue(html.contains("By A &amp; B · News &lt;Site&gt;"))
        // The Readability-cleaned body HTML is inserted verbatim.
        XCTAssertTrue(html.contains("<p>Hello <em>world</em></p>"))
    }

    func testMetaLineOmittedWhenAbsent() {
        let bare = Article(title: "T", byline: nil, siteName: nil, content: "<p>x</p>")
        XCTAssertFalse(ReaderPage.html(article: bare)
            .contains("class=\"meta\""))
    }

    func testDefaultSettingsBakeStockDesign() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("--reader-size: 17px;"))
        XCTAssertTrue(html.contains("--reader-leading: 1.6;"))
        XCTAssertTrue(html.contains("--reader-width: 42rem;"))
        XCTAssertTrue(html.contains("--reader-font: ui-serif, \"New York\", Georgia, serif;"))
        // Auto theme = no data-theme attribute, appearance follows the system.
        XCTAssertTrue(html.contains("<html lang=\"en\">"))
    }

    func testSettingsAreBakedIntoVarsAndTheme() {
        var settings = ReaderSettings()
        settings.fontSize = 22
        settings.fontFamily = .sans
        settings.width = .wide
        settings.lineHeight = .relaxed
        settings.theme = .sepia
        let html = ReaderPage.html(article: article, settings: settings)
        XCTAssertTrue(html.contains("<html lang=\"en\" data-theme=\"sepia\">"))
        XCTAssertTrue(html.contains("--reader-size: 22px;"))
        XCTAssertTrue(html.contains("--reader-leading: 1.8;"))
        XCTAssertTrue(html.contains("--reader-width: 52rem;"))
        XCTAssertTrue(html.contains("--reader-font: -apple-system,"))
        // The popover script is seeded with the same settings it renders.
        XCTAssertTrue(html.contains(settings.json))
    }

    func testPopoverButtonsAndPanelsAreLabelled() {
        // The chrome buttons are unlabelled visually, so each needs a hover tooltip and
        // each panel must name itself once opened.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("title=\"Recent articles\""))
        XCTAssertTrue(html.contains("title=\"Hidden text\""))
        XCTAssertTrue(html.contains("title=\"Text &amp; appearance\""))
        XCTAssertTrue(html.contains(">Recent articles</h2>"))
        XCTAssertTrue(html.contains(">Hidden text</h2>"))
        XCTAssertTrue(html.contains(">Text &amp; appearance</h2>"))
        XCTAssertTrue(html.contains("aria-labelledby=\"readerRecentsTitle\""))
        XCTAssertTrue(html.contains("aria-labelledby=\"readerHiddenTitle\""))
        XCTAssertTrue(html.contains("aria-labelledby=\"readerPanelTitle\""))
        // The A/A size row doesn't self-explain either.
        XCTAssertTrue(html.contains("title=\"Smaller text\""))
        XCTAssertTrue(html.contains("title=\"Larger text\""))
    }

    func testContainsAppearancePopoverAndBridge() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("id=\"readerAa\""))
        XCTAssertTrue(html.contains("messageHandlers.readerSettings.postMessage"))
        // Every adjustable value has a control.
        for value in ["serif", "sans", "narrow", "normal", "wide", "compact", "relaxed",
                      "auto", "light", "sepia", "dark", "black", "bordered", "italic"] {
            XCTAssertTrue(html.contains("data-value=\"\(value)\""), value)
        }
    }

    func testQuoteStyleIsAnAttributeOnlyWhenItalic() {
        XCTAssertTrue(ReaderPage.html(article: article).contains("<html lang=\"en\">"))
        var settings = ReaderSettings()
        settings.quoteStyle = .italic
        let html = ReaderPage.html(article: article, settings: settings)
        XCTAssertTrue(html.contains("<html lang=\"en\" data-quotes=\"italic\">"))
        // Both treatments are in the stylesheet; the attribute just switches.
        XCTAssertTrue(html.contains("article p.qp { padding-left: 14px; border-left: 3px solid var(--border); }"))
        XCTAssertTrue(html.contains(":root[data-quotes=\"italic\"] article .q { font-weight: inherit; font-style: italic; }"))
    }

    func testHiddenHitsFeedTheBadge() {
        let hit = Article(title: "T", byline: nil, siteName: nil, content: "<p>x</p>",
                          hiddenHits: ["annonce": 2, "</script>": 1])
        let html = ReaderPage.html(article: hit)
        XCTAssertTrue(html.contains("id=\"readerHiddenCount\" class=\"badge\" hidden"))
        XCTAssertTrue(html.contains("var HITS = {\"<\\/script>\":1,\"annonce\":2};"))
        XCTAssertTrue(html.contains("Removed from this article"))
        // No article, no hits: the start page bakes an empty map.
        XCTAssertTrue(StartPage.html(appName: "R").contains("var HITS = {};"))
    }

    func testHiddenTextPanelIsScriptFilledAndPhrasesCannotEscapeTheScript() {
        let html = ReaderPage.html(article: article,
                                   hidden: HiddenPhrases(["</script><img src=x onerror=alert(1)>"]))
        XCTAssertTrue(html.contains("id=\"readerHiddenList\""))
        XCTAssertTrue(html.contains("window.readerSetHidden = function"))
        XCTAssertTrue(html.contains("messageHandlers.readerUnhide.postMessage"))
        // The phrase reaches the page only as a JS string literal — and one that can't end
        // the <script> block early. The one legitimate </script> is the page's own.
        XCTAssertFalse(html.contains("</script><img"))
        XCTAssertTrue(html.contains("<\\/script><img src=x onerror=alert(1)>"))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 1)
    }

    func testRecentsPanelListsTitlesAndEscapesThem() {
        var history = ReaderHistory()
        history.record(title: "Older piece", url: "https://news.example.com/older")
        history.record(title: "Tips & <script>", url: "https://blog.example.com/tips?a=1")
        let html = ReaderPage.html(article: article, history: history)
        XCTAssertTrue(html.contains("id=\"readerRecentsBtn\""))
        XCTAssertTrue(html.contains("messageHandlers.readerOpen.postMessage"))
        // Newest first, titles escaped — they come from other sites' pages.
        XCTAssertTrue(html.contains("Tips &amp; &lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>Tips"))
        XCTAssertTrue(html.contains("data-url=\"https://blog.example.com/tips?a=1\""))
        // The host is shown as a second line on each row.
        XCTAssertTrue(html.contains("blog.example.com"))
        XCTAssertTrue(html.contains("news.example.com"))
        let newest = try? XCTUnwrap(html.range(of: "Tips &amp; &lt;script&gt;"))
        let oldest = try? XCTUnwrap(html.range(of: "Older piece"))
        XCTAssertTrue(newest!.lowerBound < oldest!.lowerBound)
    }

    func testRecentsPanelEmptyState() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("No recent articles"))
        XCTAssertFalse(html.contains("data-url="))
        // Nothing to clear, so no clear action.
        XCTAssertFalse(html.contains("id=\"readerClear\""))
    }

    func testAllPopoversAreRightAnchored() {
        // The controls sit at the window's right edge, so a panel must hang leftward or
        // it runs off screen. Regression guard: left-anchoring the recents panel pushed
        // most of it out of the viewport.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("#readerPanel, #readerRecents, #readerHidden {"))
        XCTAssertTrue(html.contains("position: absolute; top: calc(100% + 8px); right: 0;"))
        XCTAssertFalse(html.contains("left: 0; right: auto;"))
        // …and it's kept from overflowing the opposite edge on a narrow window.
        XCTAssertTrue(html.contains("max-width: calc(100vw - 28px)"))
    }

    func testRecentsPanelOffersClearWhenNonEmpty() {
        var history = ReaderHistory()
        history.record(title: "Something", url: "https://example.com/s")
        let html = ReaderPage.html(article: article, history: history)
        XCTAssertTrue(html.contains("id=\"readerClear\""))
        XCTAssertTrue(html.contains("messageHandlers.readerClear.postMessage"))
    }

    func testRecentsRowTitleCannotBreakOutOfItsAttribute() {
        // A crafted URL must not escape the data-url attribute into new markup.
        var history = ReaderHistory()
        history.record(title: "Evil", url: "https://example.com/\" onclick=\"alert(1)")
        let html = ReaderPage.html(article: article, history: history)
        XCTAssertFalse(html.contains("onclick=\"alert(1)\""))
        XCTAssertTrue(html.contains("&quot; onclick=&quot;"))
    }

    func testHasAReadingProgressBar() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("id=\"readerProgress\""))
        // Themed, so it follows the chosen palette rather than a fixed color.
        // Not the accent — that's the native load line's color, and a still blue bar
        // reads as a stuck load.
        XCTAssertTrue(html.contains("background: var(--fg);"))
        // Matches the native load line's height so the two read as one idiom.
        XCTAssertTrue(html.contains("height: 2.5px;"))
        // Decorative: a scroll fraction is nothing for a screen reader to announce.
        XCTAssertTrue(html.contains("aria-hidden=\"true\"></div>"))
    }

    func testProgressBarStartsHiddenAndScalesRatherThanResizes() {
        let html = ReaderPage.html(article: article)
        // Hidden until the script confirms the article scrolls — otherwise a short piece
        // would show a permanently full bar.
        XCTAssertTrue(html.contains("<div id=\"readerProgress\" hidden"))
        XCTAssertTrue(html.contains("transform: scaleX(0);"))
        XCTAssertTrue(html.contains("transform-origin: left center;"))
        // scaleX composites; animating width would force layout every frame.
        XCTAssertTrue(html.contains("'scaleX(' + fraction + ')'"))
        XCTAssertFalse(html.contains("bar.style.width"))
    }

    func testProgressScriptClampsAndCoalesces() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("Math.min(1, Math.max(0, fraction))"))
        // One write per frame, and a scroll listener that can't block scrolling.
        XCTAssertTrue(html.contains("requestAnimationFrame"))
        XCTAssertTrue(html.contains("{ passive: true }"))
        // Type metrics change scrollability, so the appearance popover re-measures.
        XCTAssertTrue(html.contains("window.readerOnLayoutChange = measure"))
        XCTAssertTrue(html.contains("if (window.readerOnLayoutChange)"))
    }

    func testProgressBarSitsBelowThePopovers() {
        // An open popover must not be crossed by the colored line: controls are z-index 10.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("height: 2.5px; z-index: 9;"))
        XCTAssertTrue(html.contains("right: 14px; z-index: 10;"))
    }

    func testIsACompleteStandaloneDocument() {
        // Loaded via loadHTMLString as its own document — the doctype keeps WebKit in
        // standards mode (see #76 for why the reader must be a separate document).
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<html lang=\"en\">"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }
}
