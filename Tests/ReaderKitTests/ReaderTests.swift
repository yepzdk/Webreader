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

final class ArticleLeadImageTests: XCTestCase {
    func testDecodesTheLeadImage() {
        let json = """
        {"title":"T","content":"<p>x</p>","image":"https://x.test/lead.jpg"}
        """
        XCTAssertEqual(Reader.decode(json)?.image, "https://x.test/lead.jpg")
    }

    func testAnArticleCachedBeforeTheImageExistedStillDecodes() {
        // ArticleCache blobs on disk predate #25 and carry no image key.
        let article = Reader.decode("{\"title\":\"T\",\"content\":\"<p>x</p>\"}")
        XCTAssertNotNil(article)
        XCTAssertNil(article?.image)
    }

    func testTheImageSurvivesTheCacheRoundTrip() {
        let article = Article(title: "T", byline: nil, siteName: nil, content: "<p>x</p>",
                              image: "https://x.test/lead.jpg")
        let data = try! JSONEncoder().encode(article)
        XCTAssertEqual(try! JSONDecoder().decode(Article.self, from: data), article)
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

final class ThumbnailSettingTests: XCTestCase {
    func testDecodesAndRoundTrips() {
        var settings = ReaderSettings()
        XCTAssertEqual(settings.startPageThumbnails, .on, "images are the point of the feature")
        XCTAssertEqual(settings.readerThumbnails, .on)
        settings.readerThumbnails = .off
        let decoded = ReaderSettings.fromJSON(settings.json)
        XCTAssertEqual(decoded.readerThumbnails, .off)
        XCTAssertEqual(decoded.startPageThumbnails, .on, "one surface off leaves the other on")
        XCTAssertEqual(decoded.json, settings.json)
    }

    func testAStoredBlobFromBeforeTheSettingKeepsImagesOn() {
        let settings = ReaderSettings.fromJSON("{\"fontSize\":17}")
        XCTAssertEqual(settings.startPageThumbnails, .on)
        XCTAssertEqual(settings.readerThumbnails, .on)
    }

    func testAnUnrecognisedValueKeepsTheDefault() {
        // A future value, or a hand-edited blob, must not silently turn
        // the feature off by accident.
        XCTAssertEqual(ReaderSettings.decode(["readerThumbnails": "nonsense"]).readerThumbnails, .on)
        XCTAssertEqual(ReaderSettings.decode(["readerThumbnails": "off"]).readerThumbnails, .off)
    }

    func testTheOneShippedSwitchSeedsBoth() {
        // 0.11.0 stored `startPageImages`, when the start page was the only surface with
        // thumbnails. Someone who turned it off asked for no thumbnails, so the reader's
        // popover must not arrive switched on and fetch what they opted out of.
        let migrated = ReaderSettings.fromJSON("{\"startPageImages\":\"off\"}")
        XCTAssertEqual(migrated.startPageThumbnails, .off)
        XCTAssertEqual(migrated.readerThumbnails, .off)
        // …and an explicit new key still wins over the legacy one in the same blob.
        let mixed = ReaderSettings.decode(["startPageImages": "off", "readerThumbnails": "on"])
        XCTAssertEqual(mixed.startPageThumbnails, .off)
        XCTAssertEqual(mixed.readerThumbnails, .on)
        // Only the current keys are written back.
        XCTAssertFalse(ReaderSettings().json.contains("startPageImages"))
    }

    func testEachPageBakesItsOwnSwitchAndNoOther() {
        // Each page renders only its own lists, so one attribute per page decides it. Tested
        // on the html tag: the `[data-thumbs="off"]` rules are in both pages' stylesheets.
        let article = Article(title: "T", byline: nil, siteName: nil, content: "<p>x</p>")
        var settings = ReaderSettings()
        settings.startPageThumbnails = .off
        XCTAssertTrue(StartPage.html(appName: "R", settings: settings)
            .contains("<html lang=\"en\" data-thumbs=\"off\">"))
        XCTAssertTrue(ReaderPage.html(article: article, settings: settings)
            .contains("<html lang=\"en\">"))
        settings.startPageThumbnails = .on
        settings.readerThumbnails = .off
        XCTAssertTrue(ReaderPage.html(article: article, settings: settings)
            .contains("<html lang=\"en\" data-thumbs=\"off\">"))
        XCTAssertTrue(StartPage.html(appName: "R", settings: settings)
            .contains("<html lang=\"en\">"))
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

    func testRecognizesItsOwnReaderDocumentBeforeExtracting() {
        let script = Reader.extractionScript()
        let marker = script.range(of: "meta[name=\"generator\"][content=\"WebReader\"]")!
        let gate = script.range(of: "isProbablyReaderable(document)")!
        XCTAssertTrue(marker.lowerBound < gate.lowerBound)
        XCTAssertTrue(script.contains("return \"\(Reader.ownPageSentinel)\";"))
        // The sentinel is not an article.
        XCTAssertNil(Reader.decode(Reader.ownPageSentinel))
        // …and every reader page carries the marker.
        XCTAssertTrue(ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil, content: ""))
            .contains("<meta name=\"generator\" content=\"WebReader\">"))
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

final class LeadImageExtractionTests: XCTestCase {
    func testTheScriptReadsThePagesNominatedImage() {
        let script = Reader.extractionScript()
        XCTAssertTrue(script.contains("meta[property=\"og:image\"]"))
        XCTAssertTrue(script.contains("meta[name=\"twitter:image\"]"))
        XCTAssertTrue(script.contains("image: readerLeadImage()"))
    }

    func testTheImageIsAbsolutisedAndSchemeRestricted() {
        // The start page is an about:blank document, so a relative URL resolves to nothing;
        // and the value is somebody else's markup, so only http(s) belongs in an <img src>.
        let script = Reader.extractionScript()
        XCTAssertTrue(script.contains("new URL(raw.trim(), document.baseURI)"))
        XCTAssertTrue(script.contains("url.protocol === 'http:' || url.protocol === 'https:'"))
    }

    func testTheLookupReadsTheLiveDocumentNotTheParsedCopy() {
        // Readability's result carries no image field, and the DOMParser copy is a filtered
        // body — the meta tags only exist on the real document.
        XCTAssertTrue(Reader.extractionScript().contains("document.querySelector(selectors[i])"))
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
        XCTAssertTrue(html.contains("readerPost('readerSettings'"))
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
        XCTAssertTrue(html.contains("readerPost('readerUnhide'"))
        // The phrase reaches the page only as a JS string literal — and one that can't end
        // the <script> block early. Asserted as balance rather than a fixed count: the page
        // legitimately carries two blocks now (the transport in <head> and its own at the
        // end), and a phrase that broke out would add a closer without an opener.
        XCTAssertFalse(html.contains("</script><img"))
        XCTAssertTrue(html.contains("<\\/script><img src=x onerror=alert(1)>"))
        XCTAssertEqual(html.components(separatedBy: "</script>").count,
                       html.components(separatedBy: "<script>").count)
    }

    func testRecentsPanelListsTitlesAndEscapesThem() {
        var history = ReaderHistory()
        history.record(title: "Older piece", url: "https://news.example.com/older")
        history.record(title: "Tips & <script>", url: "https://blog.example.com/tips?a=1")
        let html = ReaderPage.html(article: article, history: history)
        XCTAssertTrue(html.contains("id=\"readerRecentsBtn\""))
        XCTAssertTrue(html.contains("readerPost('readerOpen'"))
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
        XCTAssertTrue(html.contains("readerPost('readerClear'"))
    }

    // MARK: - Recents popover: five and five (#33)

    func testThePopoverListsFiveRecentsNotThirty() {
        // The panel used to be the whole 30-entry history in a 60vh scroller.
        var history = ReaderHistory()
        for index in 1...12 {
            history.record(title: "Article \(index)", url: "https://x.test/\(index)")
        }
        let html = ReaderPage.html(article: article, history: history)
        XCTAssertEqual(html.components(separatedBy: "class=\"recent\" data-url=").count - 1,
                       ReaderChrome.popoverRecents)
        // Newest first, so the oldest of the twelve is not in the panel.
        XCTAssertTrue(html.contains("Article 12"))
        XCTAssertFalse(html.contains("Article 1<"))
    }

    func testThePopoverSkipsTheArticleBeingRead() {
        // The article is recorded before the page renders, so without this it is always row
        // one — a fifth of the panel spent on what is already on screen.
        var history = ReaderHistory()
        history.record(title: "Older", url: "https://x.test/older")
        history.record(title: "On screen", url: "https://x.test/current")
        let html = ReaderPage.html(article: article, history: history,
                                   currentURL: "https://x.test/current")
        XCTAssertFalse(html.contains("data-url=\"https://x.test/current\""))
        XCTAssertTrue(html.contains("data-url=\"https://x.test/older\""))
    }

    func testTheSuggestedGroupShipsEmptyHiddenAndNamed() {
        // The host fills it after the page lands, and may never fill it at all — no sources,
        // no network — so the panel has to be complete without it.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("<section id=\"readerSuggested\" hidden aria-labelledby=\"readerSuggestedTitle\">"))
        XCTAssertTrue(html.contains("id=\"readerSuggestedList\""))
        XCTAssertTrue(html.contains("window.readerSetSuggestions = function"))
        XCTAssertFalse(html.contains("data-url="))
        // A heading, not a paragraph: it is the second of the panel's two groups, and the
        // other one names itself with an <h2>. Heading navigation has to reach it.
        XCTAssertTrue(html.contains("<h3 class=\"panel-group rest\" id=\"readerSuggestedTitle\">Suggested</h3>"))
    }

    func testTheSuggestedGroupIsCappedAndCarriesNoRowControls() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains(".slice(0, \(ReaderChrome.popoverSuggestions))"))
        // More/Less/Block are the start page's; their handlers are gated to it, and three
        // icon buttons do not fit a 280px row.
        XCTAssertFalse(html.contains("readerTopicFeedback"))
        XCTAssertFalse(html.contains("readerBlockHost"))
        // Rows open through the panel's existing listener.
        XCTAssertTrue(html.contains("readerPost('readerOpen'"))
    }

    func testTheStartPageKeepsItsOwnRicherSuggestionRows() {
        // Both pages implement the same host call; the popover's version installs only where
        // its container exists, so neither can shadow the other.
        let html = StartPage.html(appName: "Reader")
        XCTAssertTrue(html.contains("if (suggested && suggestedList) {"))
        XCTAssertTrue(html.contains("readerTopicFeedback"))
        XCTAssertEqual(html.components(separatedBy: "window.readerSetSuggestions = function").count - 1, 2)
    }

    func testClearingHistoryEmptiesOnlyTheRecentsGroup() {
        // The clear action used to strip every `.recent` in the panel; with a second list
        // below it that would take the suggestions with it.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("recentsList.textContent = '';"))
        XCTAssertFalse(html.contains("recents.querySelectorAll('.recent, #readerClear')"))
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
        XCTAssertTrue(html.contains("height: \(LoadProgress.lineThickness)px;"))
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
        // Only the stacking matters here, so only the stacking is asserted — the offsets
        // beside it are safe-area expressions and have their own test.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("height: \(LoadProgress.lineThickness)px; z-index: 9;"))
        XCTAssertTrue(html.contains("z-index: 10;"))
    }

    // MARK: - Nav slot

    func testReaderOffersAWayHome() {
        // Before #15 the only route back to the start page was a menu item — and on Linux
        // there is no menu bar at all.
        let page = ReaderPage.html(article: article)
        XCTAssertTrue(page.contains("<div class=\"reader-nav\">"))
        XCTAssertTrue(page.contains("id=\"readerHomeBtn\""))
        XCTAssertTrue(page.contains("readerPost('readerHome'"))
        // The slot's occupant here is Home, never the start page's Settings button.
        XCTAssertFalse(page.contains("id=\"startSettings\""))
    }

    // MARK: - Rating the article being read

    func testReaderOffersRatingButtons() {
        let page = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                   content: "<p>x</p>"))
        XCTAssertTrue(page.contains("id=\"readerMoreBtn\""))
        XCTAssertTrue(page.contains("id=\"readerLessBtn\""))
        XCTAssertTrue(page.contains("readerRate"))
        // An opinion you can see and take back, not a fire-and-forget click.
        XCTAssertTrue(page.contains("window.readerSetRating"))
        XCTAssertTrue(page.contains("aria-pressed=\"false\""))
        // Confirmation shares the start page's toast.
        XCTAssertTrue(page.contains("id=\"readerToast\""))
    }

    func testCurrentRatingIsBakedIntoTheButtons() {
        let article = Article(title: "T", byline: nil, siteName: nil, content: "<p>x</p>")
        // Unrated: neither button reads as pressed.
        let neutral = ReaderPage.html(article: article)
        XCTAssertTrue(neutral.contains("title=\"More like this\" aria-pressed=\"false\""))
        XCTAssertTrue(neutral.contains("title=\"Less like this\" aria-pressed=\"false\""))

        let liked = ReaderPage.html(article: article, rating: .more)
        XCTAssertTrue(liked.contains("title=\"More like this\" aria-pressed=\"true\""))
        XCTAssertTrue(liked.contains("title=\"Less like this\" aria-pressed=\"false\""))

        let disliked = ReaderPage.html(article: article, rating: .less)
        XCTAssertTrue(disliked.contains("title=\"More like this\" aria-pressed=\"false\""))
        XCTAssertTrue(disliked.contains("title=\"Less like this\" aria-pressed=\"true\""))
    }

    func testStartPageHasNoRatingButtons() {
        // There is no article to rate on the start page, so the shared chrome omits the
        // buttons. The shared script still carries the handler — guarded on the buttons
        // existing, like the progress bar — so it is inert here.
        let page = StartPage.html(appName: "Reader")
        XCTAssertFalse(page.contains("id=\"readerMoreBtn\""))
        XCTAssertFalse(page.contains("id=\"readerLessBtn\""))
        XCTAssertTrue(page.contains("if (moreBtn && lessBtn)"))
    }

    func testIsACompleteStandaloneDocument() {
        // Loaded via loadHTMLString as its own document — the doctype keeps WebKit in
        // standards mode (see #76 for why the reader must be a separate document).
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<html lang=\"en\">"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    func testHideAffordanceIsWiredIntoThePage() {
        // The floating "Hide text" button is created by its own script, so the page carries
        // no markup for it — both halves have to be interpolated or it silently never
        // appears. HiddenPhrasesTests owns its behaviour; this only guards the wiring.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("#readerHideBtn {"))
        XCTAssertTrue(html.contains("readerPost('readerHide'"))
    }
}

// MARK: - The chrome backdrop

/// The gradient behind the fixed chrome. Without it the article scrolls through the gaps
/// between the buttons — each button's own `--bg` covers only itself — and neither the text
/// nor the icons are readable. Reported from a real device, so these pin the parts that
/// would let it come back.
final class ChromeBackdropTests: XCTestCase {
    private let article = Article(title: "T", byline: nil, siteName: nil,
                                  content: "<p>x</p>", image: nil)

    func testItSitsUnderEveryPieceOfChromeAndOverTheArticle() {
        // The stacking order is the whole design: above the article (normal flow), below the
        // hide affordance (8), the progress line (9) and the chrome itself (10). One wrong
        // number and it either does nothing or hides the controls it exists to make legible.
        let css = ReaderChrome.backdropCSS()
        XCTAssertTrue(css.contains("z-index: 7;"))
        let reader = ReaderPage.html(article: article)
        for (element, z) in [("#readerHideBtn", 8), ("#readerProgress", 9)] {
            XCTAssertTrue(reader.contains("z-index: \(z);"), "\(element) moved")
        }
        XCTAssertTrue(reader.contains("z-index: 10;"))
    }

    func testItNeverSwallowsATapMeantForTheArticle() {
        // It is a band across the top of every page; without this it would eat every tap
        // and selection drag that started up there.
        XCTAssertTrue(ReaderChrome.backdropCSS().contains("pointer-events: none;"))
    }

    func testItFadesFromThePageBackgroundSoNoSeamShows() {
        // The opaque stop has to *be* the page background, not a colour that resembles it,
        // or a hard edge appears across the page. Reading `--bg` also means it follows every
        // theme — and a host-supplied palette for `auto` — with no extra rule.
        XCTAssertTrue(ReaderChrome.backdropCSS().contains(
            "background: linear-gradient(to bottom, var(--bg) 0%, var(--bg) 65%, transparent 100%);"))
    }

    func testItIsARoomyLayoutDeviceAndRetiresWhenCompact() {
        // In the roomy layout the cluster ends 41px down, and 65% of 72px is 47px — so the
        // buttons sit on solid colour rather than on the fade.
        let css = ReaderChrome.backdropCSS()
        XCTAssertTrue(css.contains("height: calc(72px + env(safe-area-inset-top, 0px));"))
        // On a compact viewport the chrome has moved to the bottom-right, so a fade along
        // the top edge would cover nothing. Retired rather than resized — and keyed on the
        // same condition the chrome is, or the two could disagree about where the chrome is.
        XCTAssertTrue(css.contains("@media \(ReaderChrome.compactViewport) {\n"
                                   + "  #readerBackdrop { display: none; }"))
    }

    func testEveryScrollingPageCarriesItAndTheOfflinePageDoesNot() {
        // Both halves or it silently never appears, like the hide affordance above.
        for (name, html) in [
            "reader": ReaderPage.html(article: article),
            "start": StartPage.html(appName: "R"),
            "settings": SettingsPage.html(appName: "R"),
        ] {
            XCTAssertTrue(html.contains("<div id=\"readerBackdrop\" aria-hidden=\"true\"></div>"), name)
            XCTAssertTrue(html.contains("#readerBackdrop {"), name)
        }
        // The offline page is a centred card at exactly viewport height: nothing scrolls
        // under its Home button, so it needs no backdrop — and its body is a flex container,
        // which is a reason not to add stray children to it on a hunch.
        let offline = OfflineFallback.html(appName: "R", host: "example.com", kind: .offline)
        XCTAssertFalse(offline.contains("readerBackdrop"))
    }
}

// MARK: - The page-to-host transport

/// `readerPost` is the single route every generated page has to its host. These pin the
/// two things that would silently gate the whole app shut: that each platform gets the
/// transport its web view actually offers, and that every document defines it before
/// anything can call it.
final class TransportTests: XCTestCase {
    private let article = Article(title: "T", byline: nil, siteName: nil,
                                  content: "<p>x</p>", image: nil)

    /// Every document a host can load, in the platform it is being rendered for.
    private func pages(_ platform: Platform) -> [String: String] {
        [
            "reader": ReaderPage.html(article: article, platform: platform),
            "start": StartPage.html(appName: "R", platform: platform),
            "settings": SettingsPage.html(appName: "R", platform: platform),
            "offline": OfflineFallback.html(appName: "R", host: "example.com",
                                            kind: .offline, platform: platform),
        ]
    }

    func testWebKitHostsGetTheMessageHandlersTransport() {
        // WKWebView and WebKitGTK expose the same object, which is why one branch covers
        // the two desktop hosts and iOS.
        for platform in [Platform.macOS, .linux, .iOS] {
            for (name, html) in pages(platform) {
                XCTAssertTrue(
                    html.contains("window.webkit.messageHandlers[name].postMessage(body);"),
                    "\(name) on \(platform.rawValue)")
                XCTAssertFalse(html.contains(ReaderChrome.androidBridge),
                               "\(name) on \(platform.rawValue)")
            }
        }
    }

    func testAndroidGetsTheSingleBridgeObjectAndCarriesTheNameInTheBody() {
        // Android's WebView has no `webkit` object at all. `addWebMessageListener` injects
        // one named object whose postMessage takes a single string, so the handler name has
        // to travel with the body and the host demultiplexes on the far side.
        for (name, html) in pages(.android) {
            XCTAssertTrue(html.contains("window.readerHost.postMessage("
                                        + "JSON.stringify({ name: name, body: body }));"),
                          name)
            XCTAssertFalse(html.contains("window.webkit."), name)
        }
    }

    func testEveryDocumentDefinesTheTransportBeforeItsFirstUse() {
        // The nav button and the offline page's Try Again post from an inline `onclick`, so
        // a transport defined at the end of <body> would be a race on a restored page.
        for platform in Platform.allCases {
            for (name, html) in pages(platform) {
                guard let defined = html.range(of: "window.readerPost = function"),
                      let head = html.range(of: "</head>") else {
                    return XCTFail("\(name) on \(platform.rawValue) defines no transport")
                }
                XCTAssertLessThan(defined.lowerBound, head.lowerBound,
                                  "\(name) on \(platform.rawValue) defines it after <head>")
            }
        }
    }

    func testTheGuardLivesInTheTransportRatherThanAtEveryCallSite() {
        // A page can outlive its host — restored from the back-forward cache, or opened in
        // a plain browser while working on the CSS — and must stay readable rather than
        // throwing on every click. That guard used to be repeated at all thirteen post
        // sites; it is now in one place, so no call site can forget it.
        for platform in Platform.allCases {
            let js = ReaderChrome.transportScript(platform: platform)
            XCTAssertTrue(js.contains("catch (err) {}"), platform.rawValue)
        }
        // And the reader page — the busiest poster, with seven of the thirteen sites this
        // replaced — names the host API exactly once: in the transport definition.
        let reader = ReaderPage.html(article: article)
        XCTAssertEqual(reader.components(separatedBy: "window.webkit.").count - 1, 1)
    }
}

// MARK: - Per-platform font stacks (#16)

/// `Platform` is a value rather than `#if os(...)` precisely so both platforms' stacks can
/// be asserted from whichever OS runs the suite. None of these tests is conditional on the
/// compiling OS; if one ever has to be, the abstraction has failed.
final class PlatformFontStackTests: XCTestCase {
    func testMacOSStacksAreUnchangedAppleFaces() {
        XCTAssertEqual(Platform.macOS.serifStack, "ui-serif, \"New York\", Georgia, serif")
        XCTAssertEqual(Platform.macOS.sansStack,
                       "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Arial, sans-serif")
    }

    func testLinuxStacksNameFacesThatResolveOnArch() {
        // Noto Serif leads because it ships a real Bold, which the medium-weight quotation
        // styling needs; Liberation is the everywhere-installed fallback behind it.
        XCTAssertEqual(Platform.linux.serifStack, "\"Noto Serif\", \"Liberation Serif\", serif")
        // Adwaita Sans is GTK4's UI font — the Linux counterpart to -apple-system.
        XCTAssertEqual(Platform.linux.sansStack, "\"Adwaita Sans\", \"Noto Sans\", sans-serif")
    }

    func testLinuxStacksNameNoAppleFaces() {
        // An unresolvable name is not a fallback, it's noise: on a stock Arch box every
        // Apple entry falls through to Liberation, so the chosen type is silently lost.
        for stack in [Platform.linux.serifStack, Platform.linux.sansStack] {
            XCTAssertFalse(stack.contains("-apple-system"))
            XCTAssertFalse(stack.contains("BlinkMacSystemFont"))
            XCTAssertFalse(stack.contains("New York"))
            XCTAssertFalse(stack.contains("Helvetica Neue"))
        }
    }

    func testFontFamilyResolvesThroughTheGivenPlatform() {
        XCTAssertEqual(ReaderSettings.FontFamily.serif.css(on: .macOS), Platform.macOS.serifStack)
        XCTAssertEqual(ReaderSettings.FontFamily.sans.css(on: .macOS), Platform.macOS.sansStack)
        XCTAssertEqual(ReaderSettings.FontFamily.serif.css(on: .linux), Platform.linux.serifStack)
        XCTAssertEqual(ReaderSettings.FontFamily.sans.css(on: .linux), Platform.linux.sansStack)
    }
}

/// The generated pages honour the platform they're asked for, and default to macOS so the
/// AppKit host's call sites keep compiling untouched.
final class PlatformPageTests: XCTestCase {
    private let article = Article(title: "T", byline: "By A", siteName: "S",
                                  content: "<p>x</p>")

    func testReaderPageDefaultsToTheMacOSStacks() {
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("--reader-font: \(Platform.macOS.serifStack);"))
        XCTAssertTrue(html.contains(Platform.macOS.sansStack))
    }

    func testLinuxReaderPageCarriesBothLinuxStacksAndNoAppleOne() {
        let html = ReaderPage.html(article: article, platform: .linux)
        // The reading font baked into the palette, and the chrome/meta sans beside it.
        XCTAssertTrue(html.contains("--reader-font: \(Platform.linux.serifStack);"))
        XCTAssertTrue(html.contains(Platform.linux.sansStack))
        XCTAssertFalse(html.contains("-apple-system"))
        XCTAssertFalse(html.contains("BlinkMacSystemFont"))
        XCTAssertFalse(html.contains("Helvetica Neue"))
    }

    func testLinuxSerifStackReachesThePopoverFontMap() {
        // The "Aa" popover re-sets --reader-font from its own FONTS map, so a stack that is
        // only right in the stylesheet reverts to Apple faces the moment a setting is
        // nudged. This is the assertion that would have caught that.
        let html = ReaderPage.html(article: article, platform: .linux)
        XCTAssertTrue(html.contains("var FONTS = { serif: '\(Platform.linux.serifStack)', "
                                    + "sans: '\(Platform.linux.sansStack)' };"))
    }

    func testOfflinePageHonoursThePlatform() {
        let mac = OfflineFallback.html(appName: "Reader", host: "example.com", kind: .offline)
        XCTAssertTrue(mac.contains("font: 15px/1.5 \(Platform.macOS.sansStack);"))
        let linux = OfflineFallback.html(appName: "Reader", host: "example.com", kind: .offline,
                                         platform: .linux)
        XCTAssertTrue(linux.contains("font: 15px/1.5 \(Platform.linux.sansStack);"))
        XCTAssertFalse(linux.contains("-apple-system"))
    }

    func testStartAndSettingsPagesHonourThePlatform() {
        let start = StartPage.html(appName: "Reader", platform: .linux)
        XCTAssertTrue(start.contains(Platform.linux.sansStack))
        XCTAssertFalse(start.contains("-apple-system"))

        let settings = SettingsPage.html(appName: "Reader", platform: .linux)
        XCTAssertTrue(settings.contains(Platform.linux.sansStack))
        XCTAssertFalse(settings.contains("-apple-system"))
    }
}
