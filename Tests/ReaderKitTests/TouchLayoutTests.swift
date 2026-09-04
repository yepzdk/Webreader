import XCTest
@testable import ReaderKit

/// The touch-readiness invariants of the generated pages (#36).
///
/// Every assertion here corresponds to a defect that was found by measuring the rendered
/// pages in a touch-emulating browser at 320/390/412px portrait and landscape, and each
/// would be silently reintroduced by an innocent-looking CSS edit. They are string
/// assertions over generated CSS because that is what ReaderKit produces — the geometry
/// itself is verified by driving a real web view, which no unit test can do.
///
/// None of these is conditional on the compiling OS: `Platform` is a value, and the CSS is
/// the same bytes whoever built it.
final class TouchLayoutTests: XCTestCase {
    private let article = Article(title: "T", byline: nil, siteName: nil,
                                  content: "<p>x</p>", image: nil)

    private func pages(_ platform: Platform) -> [String: String] {
        [
            "reader": ReaderPage.html(article: article, platform: platform),
            "start": StartPage.html(appName: "R", platform: platform),
            "settings": SettingsPage.html(appName: "R", platform: platform),
            "offline": OfflineFallback.html(appName: "R", host: "example.com",
                                            kind: .offline, platform: platform),
        ]
    }

    // MARK: - The reveal that hid working controls

    func testRowActionsAreHiddenOnlyWhereAPointerCanHover() {
        // The defect this pins: `.row-actions { opacity: 0 }` with a `:hover` reveal made
        // More/Less/Block permanently invisible AND unreachable on a touch screen. The rule
        // has to be inside a `hover: hover` query — visible by default, hidden only where
        // hovering is possible.
        let css = StartPage.html(appName: "R")
        guard let query = css.range(of: "@media (hover: hover) {"),
              let hide = css.range(of: ".row-actions { opacity: 0; }") else {
            return XCTFail("the row-action reveal must be gated on hover capability")
        }
        XCTAssertGreaterThan(hide.lowerBound, query.lowerBound,
                             "opacity: 0 must sit inside the hover query, not before it")
        // The keyboard route survives alongside the pointer one.
        XCTAssertTrue(css.contains(".row-actions:focus-within { opacity: 1; }"))
    }

    // MARK: - Safe-area insets

    func testEveryFixedChromeElementIsSafeAreaAware() {
        // A notch, a rounded corner or a home indicator otherwise lands on top of a control.
        // Each of these is a `position: fixed` element pinned to a window edge.
        let reader = ReaderPage.html(article: article)
        for offset in [
            "top: calc(14px + env(safe-area-inset-top, 0px))",       // nav + controls
            "bottom: calc(20px + env(safe-area-inset-bottom, 0px))", // toast
            "top: env(safe-area-inset-top, 0px)",                    // progress hairline
        ] {
            XCTAssertTrue(reader.contains(offset), offset)
        }
    }

    func testSafeAreaInsetsAlwaysCarryAnExplicitFallback() {
        // `env()` with no fallback makes the whole declaration invalid on an engine that
        // does not implement it — and an invalid declaration is dropped, so the chrome would
        // lose its offset entirely rather than fall back to it. Every use must pass 0px.
        for platform in Platform.allCases {
            for (name, html) in pages(platform) {
                let uses = html.components(separatedBy: "env(safe-area-inset-").count - 1
                let guarded = html.components(separatedBy: ", 0px)").count - 1
                XCTAssertGreaterThan(uses, 0, "\(name) on \(platform.rawValue)")
                XCTAssertEqual(uses, guarded,
                               "\(name) on \(platform.rawValue) has an unguarded env()")
            }
        }
    }

    // MARK: - Popover anchoring

    func testTouchPopoversArePinnedToTheViewportNotTheirButton() {
        // Measured at -47px off the left edge before this: each panel is `right: 0` inside
        // its own `.reader-control`, and the recents button is the third of five, so its
        // right edge is ~273px in on a 390px phone. A panel wider than that starts
        // off-screen, and the `max-width` guard never fires because the panel is narrower
        // than the viewport while still outside it. Re-anchoring is the only fix.
        let css = ReaderChrome.controlsCSS()
        guard let coarse = css.range(of: "@media (pointer: coarse) {") else {
            return XCTFail("the controls need a coarse-pointer block")
        }
        let touch = String(css[coarse.lowerBound...])
        XCTAssertTrue(touch.contains("#readerPanel, #readerRecents, #readerHidden {"))
        XCTAssertTrue(touch.contains("position: fixed;"))
        XCTAssertTrue(touch.contains("left: max(14px, env(safe-area-inset-left, 0px));"))
        XCTAssertTrue(touch.contains("right: max(14px, env(safe-area-inset-right, 0px));"))
        // Below the chrome: a 14px inset, a 44px button and the 8px gap the pointer uses.
        XCTAssertTrue(touch.contains("top: calc(66px + env(safe-area-inset-top, 0px));"))
        // And capped, so a landscape phone doesn't get an 816px band of 13px rows.
        XCTAssertTrue(touch.contains("max-width: 30rem; margin-left: auto;"))
    }

    func testThePointerLayoutStillAnchorsPopoversToTheirButton() {
        // The desktop behaviour is unchanged: absolute, under the button that opened it,
        // with the guard against running off the opposite edge that the Aa panel was
        // missing. The coarse block above overrides these; it must not replace them.
        let css = ReaderChrome.controlsCSS()
        XCTAssertTrue(css.contains("position: absolute; top: calc(100% + 8px); right: 0;"))
        XCTAssertTrue(css.contains("max-width: calc(100vw - 28px);"))
        // And the override comes later, or source order would leave the desktop rule on top.
        // Anchored on the landscape cap, which appears only in the coarse block — a bare
        // `position: fixed` also matches `.reader-controls` itself, at the top of the file.
        guard let absolute = css.range(of: "position: absolute; top: calc(100% + 8px)"),
              let override = css.range(of: "max-width: 30rem; margin-left: auto;") else {
            return XCTFail("both anchorings must be present")
        }
        XCTAssertLessThan(absolute.lowerBound, override.lowerBound)
    }

    // MARK: - Touch targets

    func testEveryChromeButtonReachesTheTouchFloorTogether() {
        // The floor lives in `buttonBox`, which both the nav slot and the control cluster
        // render, so a button on one side of the window cannot grow without the other.
        for css in [ReaderChrome.navCSS(), ReaderChrome.controlsCSS()] {
            XCTAssertTrue(css.contains("min-height: 44px; min-width: 44px; padding: 4px 14px;"))
        }
        // The rating pair carries its own box (so the pressed accent can override it) and so
        // needs the floor stated separately — it was missed the first time and measured 27px.
        // Matched without leading whitespace: the fragment is re-indented per call site.
        XCTAssertTrue(ReaderChrome.controlsCSS()
            .contains("min-height: 44px; min-width: 44px; padding: 5px 12px;"))
    }

    func testTextFieldsAvoidTheMobileSafariZoom() {
        // Mobile Safari zooms the whole page in when focusing an input under 16px, which
        // throws the layout off and needs a pinch to undo. Both fields go to 16px on touch.
        XCTAssertTrue(StartPage.html(appName: "R")
            .contains("#url { padding: 12px 12px; font-size: 16px; min-height: 44px; }"))
        XCTAssertTrue(SettingsPage.html(appName: "R")
            .contains("#source { padding: 12px; font-size: 16px; min-height: 44px; }"))
    }

    // MARK: - Behaviour that follows the host, not the viewport

    func testOnlyAKeyboardHostAutofocusesTheURLField() {
        // On a phone autofocus throws the soft keyboard over the recents list before the
        // page has been read. On a desktop it saves a click before a paste.
        for platform in Platform.allCases {
            let html = StartPage.html(appName: "R", platform: platform)
            XCTAssertEqual(html.contains("spellcheck=\"false\" autofocus"),
                           platform.hasKeyboardCommands, platform.rawValue)
        }
    }

    func testTheClipboardHintOnlyNamesAChordAHostActuallyBinds() {
        // A hint naming a key nobody can press is worse than no hint. The whole paragraph
        // goes, rather than rendering an empty key cap.
        for platform in Platform.allCases {
            let html = StartPage.html(appName: "R", platform: platform)
            XCTAssertEqual(html.contains("to open a copied link"),
                           platform.hasKeyboardCommands, platform.rawValue)
        }
        XCTAssertFalse(StartPage.html(appName: "R", platform: .iOS).contains("<kbd>"))
    }

    func testTouchStartPageCopyNamesHowLinksActuallyArrive() {
        // There is no browser chooser and no command line on a phone; the share sheet is
        // the route, and it is the one thing a reader can be told to look for by name.
        XCTAssertTrue(StartPage.html(appName: "R", platform: .iOS)
            .contains("Share a link to this app from Safari"))
        XCTAssertTrue(StartPage.html(appName: "R", platform: .android)
            .contains("Share a link to this app from your browser"))
        for platform in [Platform.iOS, .android] {
            let html = StartPage.html(appName: "R", platform: platform)
            XCTAssertFalse(html.contains("command line"), platform.rawValue)
            XCTAssertFalse(html.contains("browser chooser"), platform.rawValue)
        }
    }

    // MARK: - Layout

    func testEveryPageClearsItsOwnFixedChrome() {
        // 18vh and 10vh top paddings are generous in portrait and less than the chrome's
        // 58px in landscape, where the heading ended up underneath the nav button. Measured
        // as an overlap on the start page at 320px and 390px before this.
        XCTAssertTrue(StartPage.html(appName: "R")
            .contains("padding-top: calc(68px + env(safe-area-inset-top, 0px));"))
        XCTAssertTrue(SettingsPage.html(appName: "R")
            .contains("padding-top: calc(68px + env(safe-area-inset-top, 0px));"))
        XCTAssertTrue(ReaderPage.html(article: article)
            .contains("main { padding-top: calc(68px + env(safe-area-inset-top, 0px)); }"))
    }

    func testTheDesktopLayoutKeepsItsGenerousTopPadding() {
        // The mobile-first base is overridden above the measure breakpoint, so the desktop
        // pages are unchanged. Both halves have to be present or one of them is dead CSS.
        let start = StartPage.html(appName: "R")
        XCTAssertTrue(start.contains("@media (min-width: 34rem) {"))
        XCTAssertTrue(start.contains("padding-top: 18vh;"))
        XCTAssertTrue(start.contains("@media (min-width: 60rem) {"))
        XCTAssertTrue(SettingsPage.html(appName: "R").contains("padding-top: 10vh;"))
    }
}
