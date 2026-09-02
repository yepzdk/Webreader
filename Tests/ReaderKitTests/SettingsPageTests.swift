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
        // Scoped to the row's own attribute: blocked outlets and hidden phrases reuse the
        // `.source` row markup, and the hidden list is never empty (it ships with defaults).
        XCTAssertFalse(page.contains("<div class=\"source\" data-url="))
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

    func testTheWayHomeIsTheSameNavSlotEveryOtherPageUses() {
        // It used to be a "Done" button after the shortcut table, which on a page with a few
        // sources sat below the fold — so the only route home was off screen (#15).
        let page = html()
        XCTAssertTrue(page.contains("<div class=\"reader-nav\">"))
        XCTAssertTrue(page.contains("id=\"readerHomeBtn\""))
        XCTAssertTrue(page.contains("messageHandlers.readerHome.postMessage"))
    }

    func testTheDoneButtonIsGone() {
        // Two routes to one action, and the label promised a commit that never happened:
        // every change on this page posts the moment it is made.
        let page = html()
        XCTAssertFalse(page.contains("id=\"done\""))
        XCTAssertFalse(page.contains(">Done<"))
        XCTAssertFalse(page.contains(".done {"))
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
        // No stored filter means every box is ticked. Counted on the language rows' own
        // shape, so the start page section's switch is not swept in.
        XCTAssertEqual(page.components(separatedBy: "\" checked><span>").count - 1, 2)
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

    func testBlockedSectionOnlyAppearsWhenSomethingIsBlocked() {
        XCTAssertFalse(html().contains("Blocked outlets"))
        var settings = SuggestionSettings()
        settings.block(host: "www.extrabladet.dk")
        let page = html(settings)
        XCTAssertTrue(page.contains("Blocked outlets"))
        // Stored and displayed in the normalized form the start page shows.
        XCTAssertTrue(page.contains("data-host=\"extrabladet.dk\""))
        XCTAssertTrue(page.contains("aria-label=\"Unblock extrabladet.dk\""))
        XCTAssertTrue(page.contains("readerUnblockHost"))
    }

    func testBlockedHostsAreEscaped() {
        var settings = SuggestionSettings()
        settings.blockedHosts = ["evil\" onload=\"alert(1)"]
        let page = html(settings)
        XCTAssertFalse(page.contains("onload=\"alert(1)\""))
    }

    // MARK: - Hidden text (#32)

    func testListsHiddenPhrasesWithAWayToDropThem() {
        // Un-hiding used to require opening the start page's copy of the reader popover;
        // with that button gone this page is where a phrase is dropped.
        let page = SettingsPage.html(appName: "WebReader",
                                     hidden: HiddenPhrases(["Artiklen fortsætter efter annoncen"]))
        XCTAssertTrue(page.contains("Hidden text"))
        XCTAssertTrue(page.contains("data-phrase=\"Artiklen fortsætter efter annoncen\""))
        XCTAssertTrue(page.contains("aria-label=\"Stop hiding Artiklen fortsætter efter annoncen\""))
        XCTAssertTrue(page.contains("readerUnhide"))
    }

    func testTheStockPhraseListIsAlreadyThere() {
        // Unlike the blocklist this is seeded, so the section is the feature's only written
        // trace on a fresh install.
        XCTAssertTrue(html().contains("Hidden text"))
        XCTAssertTrue(html().contains("data-phrase=\"Annonce\""))
    }

    func testTheHiddenSectionGoesWhenTheLastPhraseDoes() {
        let page = SettingsPage.html(appName: "WebReader", hidden: HiddenPhrases([]))
        XCTAssertFalse(page.contains("id=\"hiddenSection\""))
        XCTAssertFalse(page.contains("Hide a phrase by selecting it"))
        // The row handler drops the section with its last row, as the blocklist does.
        let seeded = html()
        XCTAssertTrue(seeded.contains("document.getElementById('hiddenSection').remove()"))
    }

    func testHiddenPhrasesAreEscaped() {
        // Phrases come from pages the user was reading, so they are someone else's text.
        let page = SettingsPage.html(appName: "WebReader",
                                     hidden: HiddenPhrases(["evil\" onload=\"alert(1)"]))
        XCTAssertFalse(page.contains("onload=\"alert(1)\""))
        XCTAssertTrue(page.contains("&quot; onload=&quot;"))
    }

    // MARK: - Article images (#33)

    func testBothThumbnailSwitchesAreOnTheSettingsPage() {
        // One switch in the Aa popover, labelled "Images / No images", read as governing the
        // article's own images. It never did — only these lists' thumbnails.
        let page = html()
        XCTAssertTrue(page.contains("<h2 class=\"section\">Article images</h2>"))
        XCTAssertTrue(page.contains("id=\"startPageThumbnails\" type=\"checkbox\" checked"))
        XCTAssertTrue(page.contains("id=\"readerThumbnails\" type=\"checkbox\" checked"))
        XCTAssertTrue(page.contains("post('readerSettings', settings)"))
        // Each says which surface it governs.
        XCTAssertTrue(page.contains("on the start page</span>"))
        XCTAssertTrue(page.contains("in the reader dropdown</span>"))
    }

    func testEachSwitchReflectsItsOwnStoredChoice() {
        var settings = ReaderSettings()
        settings.readerThumbnails = .off
        let page = SettingsPage.html(appName: "WebReader", settings: settings)
        XCTAssertTrue(page.contains("id=\"startPageThumbnails\" type=\"checkbox\" checked"))
        XCTAssertTrue(page.contains("id=\"readerThumbnails\" type=\"checkbox\">"))
    }

    func testTheSwitchesPostAWholeSettingsObject() {
        // `readerSettings` replaces the stored object, so a partial payload would reset
        // font size, theme and the rest to defaults.
        var settings = ReaderSettings()
        settings.fontSize = 22
        settings.theme = .sepia
        let page = SettingsPage.html(appName: "WebReader", settings: settings)
        XCTAssertTrue(page.contains("var settings = \(settings.json);"))
        XCTAssertTrue(page.contains("settings[key] = box.checked ? 'on' : 'off';"))
        // The box's id IS the key it writes, so the two cannot drift apart.
        XCTAssertTrue(page.contains("['startPageThumbnails', 'readerThumbnails'].forEach"))
    }

    func testIdentifiesItselfForBackForwardRestoration() {
        XCTAssertTrue(html().contains("<meta name=\"generator\" content=\"WebReader Settings\">"))
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

    // MARK: - Keyboard shortcuts

    /// The page as a given host would render it. `platform` is a value precisely so both
    /// columns are reachable from whichever OS the suite runs on — no test here branches
    /// on the compiling system.
    private func page(_ platform: Platform) -> String {
        SettingsPage.html(appName: "WebReader", platform: platform)
    }

    private let shortcutHeading = "<h2 class=\"section\">Keyboard shortcuts</h2>"

    func testShortcutSectionPrintsTheChordsOfThePlatformItRendersFor() {
        let linux = page(.linux)
        XCTAssertTrue(linux.contains(shortcutHeading))
        XCTAssertTrue(linux.contains("<kbd>Ctrl+Shift+R</kbd>"))
        XCTAssertFalse(linux.contains("⇧⌘R"))

        let mac = page(.macOS)
        XCTAssertTrue(mac.contains(shortcutHeading))
        XCTAssertTrue(mac.contains("<kbd>⇧⌘R</kbd>"))
        XCTAssertFalse(mac.contains("Ctrl+Shift+R"))
    }

    func testEveryActionAndChordInTheTableReachesBothPages() {
        // One table, two columns: a row that renders on one platform and not the other
        // means it stopped being the single source the table exists to be.
        for platform in Platform.allCases {
            let rendered = page(platform)
            for shortcut in SettingsPage.shortcuts {
                XCTAssertTrue(rendered.contains("<dt>\(HTML.escape(shortcut.action))</dt>"),
                              "\(shortcut.action) is missing from the \(platform.rawValue) page")
                for chord in shortcut.chords(for: platform) {
                    XCTAssertTrue(rendered.contains("<kbd>\(HTML.escape(chord))</kbd>"),
                                  "\(chord) is missing from the \(platform.rawValue) page")
                }
            }
        }
    }

    func testChordsMatchTheDocumentedShortcuts() {
        // Pinned against the README table and `WebReaderGTK.Application.Command`, spelled
        // out rather than derived, so a slip in the Swift table fails here instead of
        // teaching the user a chord the host never registered.
        let expected: [(action: String, macOS: String, linux: String)] = [
            ("Open URL from clipboard", "⇧⌘O", "Ctrl+Shift+O"),
            ("Toggle reader view", "⇧⌘R", "Ctrl+Shift+R"),
            ("Home (start page)", "⇧⌘H", "Ctrl+Shift+H"),
            ("Copy current URL", "⇧⌘C", "Ctrl+Shift+C"),
            ("Settings", "⌘,", "Ctrl+,"),
            ("Reload", "⌘R", "Ctrl+R"),
            ("Zoom in / out / reset", "⌘+ / ⌘− / ⌘0", "Ctrl++ / Ctrl+− / Ctrl+0"),
            ("Back / forward", "⌘[ / ⌘]", "Alt+← / Alt+→"),
        ]
        XCTAssertEqual(SettingsPage.shortcuts.count, expected.count)
        for (shortcut, want) in zip(SettingsPage.shortcuts, expected) {
            XCTAssertEqual(shortcut.action, want.action)
            XCTAssertEqual(shortcut.chords(for: .macOS).joined(separator: " / "), want.macOS)
            XCTAssertEqual(shortcut.chords(for: .linux).joined(separator: " / "), want.linux)
        }
    }

    func testBackForwardNamesWebKitGTKOnLinux() {
        // Alt+← is the web view's, not an accelerator the GTK host binds. Printing the
        // chords without saying so would read as an app feature; omitting the row would
        // read as a missing one.
        let linux = page(.linux)
        XCTAssertTrue(linux.contains("<dt>Back / forward</dt>"))
        XCTAssertTrue(linux.contains("<kbd>Alt+←</kbd>"))
        XCTAssertTrue(linux.contains("<kbd>Alt+→</kbd>"))
        XCTAssertTrue(linux.contains("class=\"key-note\">Handled by WebKitGTK, not bound by the app.<"))
        // macOS binds them itself, so there is nothing to explain there. The class is
        // always in the stylesheet, so the markup is what has to be absent.
        XCTAssertFalse(page(.macOS).contains("<span class=\"key-note\">"))
        XCTAssertFalse(page(.macOS).contains("WebKitGTK"))
    }

    func testLinuxPageSaysWhyItCarriesTheList() {
        XCTAssertTrue(page(.linux).contains("no menu bar"))
        XCTAssertFalse(page(.macOS).contains("no menu bar"))
    }

    func testShortcutSectionIsStaticTextBelowTheControls() throws {
        let rendered = page(.linux)
        // Reference, not editor: no rebinding, so no host round-trip and no new handler.
        XCTAssertFalse(rendered.contains("readerShortcut"))
        XCTAssertFalse(rendered.contains("readerSetShortcut"))
        // And it sits after the sections someone came to Settings to change, and is the last
        // thing in the document — it used to be followed by a "Done" button (#15).
        let sources = try XCTUnwrap(rendered.range(of: "<h2 class=\"section\">Suggestion sources</h2>"))
        let keys = try XCTUnwrap(rendered.range(of: shortcutHeading))
        let end = try XCTUnwrap(rendered.range(of: "</main>"))
        XCTAssertTrue(sources.lowerBound < keys.lowerBound)
        XCTAssertTrue(keys.lowerBound < end.lowerBound)
    }
}
