import XCTest
@testable import ReaderKit

// The settings page's pure HTML generation: source rows, escaping, the host hooks, and the
// conditional language section. The host wiring is hand-verified per repo convention.
final class SettingsPageTests: XCTestCase {
    private func html(_ suggestions: SuggestionSettings = SuggestionSettings()) -> String {
        SettingsPage.html(appName: "WebReader", suggestions: suggestions)
    }

    func testListsSourcesWithHostAndLanguage() {
        let page = html()
        XCTAssertTrue(page.contains("Wallnot"))
        XCTAssertTrue(page.contains("wallnot.dk"))
        XCTAssertTrue(page.contains("data-url=\"https://wallnot.dk/rss\""))
        XCTAssertTrue(page.contains("class=\"source-lang\">da<"))
    }

    func testSourceTitlesAreEscaped() {
        let page = html(SuggestionSettings(sources: [
            FeedSource(url: "https://x.test/rss\" onload=\"alert(1)", title: "News & <script>", language: nil),
        ]))
        XCTAssertTrue(page.contains("News &amp; &lt;script&gt;"))
        XCTAssertFalse(page.contains("onload=\"alert(1)\""))
    }

    func testEmptySourceListSaysSo() {
        let page = html(SuggestionSettings(sources: []))
        XCTAssertTrue(page.contains("No sources."))
        XCTAssertFalse(page.contains("class=\"source\""))
    }

    func testOffersTheAddFormAndItsHostHooks() {
        let page = html()
        XCTAssertTrue(page.contains("id=\"source\""))
        XCTAssertTrue(page.contains("readerAddSource"))
        XCTAssertTrue(page.contains("readerRemoveSource"))
        XCTAssertTrue(page.contains("window.readerSourceAdded"))
        XCTAssertTrue(page.contains("window.readerSourceRejected"))
        // The rejection is visible, not just a beep.
        XCTAssertTrue(page.contains("role=\"alert\""))
    }

    func testDoneReturnsHome() {
        XCTAssertTrue(html().contains("readerHome"))
    }

    func testLanguageSectionOnlyAppearsWithMoreThanOneLanguage() {
        // One language means no choice to make — the section's markup is absent (the
        // shared script still carries the handler, guarded on the section existing).
        XCTAssertFalse(html().contains("class=\"langs\""))
        let mixed = SuggestionSettings(sources: [
            FeedSource(url: "https://a.test/rss", title: "A", language: "da"),
            FeedSource(url: "https://b.test/rss", title: "B", language: "en"),
        ])
        let page = html(mixed)
        XCTAssertTrue(page.contains("class=\"langs\""))
        XCTAssertTrue(page.contains("readerSetLanguages"))
        XCTAssertTrue(page.contains("value=\"da\""))
        XCTAssertTrue(page.contains("value=\"en\""))
        // No stored filter means every box is ticked.
        XCTAssertEqual(page.components(separatedBy: "\" checked>").count - 1, 2)
    }

    func testStoredLanguageFilterTicksOnlyItsBoxes() {
        var settings = SuggestionSettings(sources: [
            FeedSource(url: "https://a.test/rss", title: "A", language: "da"),
            FeedSource(url: "https://b.test/rss", title: "B", language: "en"),
        ])
        settings.languages = ["da"]
        let page = html(settings)
        XCTAssertTrue(page.contains("value=\"da\" checked>"))
        XCTAssertFalse(page.contains("value=\"en\" checked>"))
    }

    func testNamesLanguagesReadably() {
        XCTAssertEqual(SettingsPage.languageName("da"), "Danish")
        XCTAssertEqual(SettingsPage.languageName("zz"), "zz")
    }

    func testNoEmojiInPage() {
        // Design convention: no emoji anywhere in the UI.
        let hasEmoji = html().unicodeScalars.contains { scalar in
            (0x1F300...0x1FAFF).contains(scalar.value) || (0x2600...0x27BF).contains(scalar.value)
        }
        XCTAssertFalse(hasEmoji, "settings page must not contain emoji")
    }

    func testIsACompleteStandaloneDocument() {
        XCTAssertTrue(html().hasPrefix("<!doctype html>"))
        XCTAssertTrue(html().hasSuffix("</html>"))
    }

    func testBakedReaderSettingsDriveThePage() {
        var settings = ReaderSettings()
        settings.theme = .dark
        let page = SettingsPage.html(appName: "WebReader", settings: settings)
        XCTAssertTrue(page.contains("<html lang=\"en\" data-theme=\"dark\">"))
    }
}
