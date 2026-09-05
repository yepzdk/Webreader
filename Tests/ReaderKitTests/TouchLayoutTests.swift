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
        //
        // Anchored to the *bottom* since the chrome moved to the bottom-right corner: a
        // panel opening at the far end of the screen from the button just pressed would be
        // a different gesture entirely.
        let css = ReaderChrome.controlsCSS()
        guard let coarse = css.range(of: "#readerPanel, #readerRecents, #readerHidden {\n"
                                         + "    position: fixed;") else {
            return XCTFail("the panels need a coarse-pointer anchoring")
        }
        let touch = String(css[coarse.lowerBound...])
        XCTAssertTrue(touch.contains("top: auto;"))
        XCTAssertTrue(touch.contains("left: max(14px, env(safe-area-inset-left, 0px));"))
        XCTAssertTrue(touch.contains("right: max(14px, env(safe-area-inset-right, 0px));"))
        // Clear of the toggle: the 14px inset, the 44px button and the 10px column gap.
        XCTAssertTrue(touch.contains("bottom: calc(68px"))
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

    func testTouchPagesClearTheBottomChromeInsteadOfTheTop() {
        // The chrome is a floating column in the bottom-right corner on a coarse pointer, so
        // the headroom goes back to what the content wants and the *foot* is what has to
        // clear it: the toggle ends 58px up, and 78px leaves the last line readable rather
        // than parked under a button.
        for html in [StartPage.html(appName: "R"), SettingsPage.html(appName: "R")] {
            XCTAssertTrue(html.contains("padding-top: 32px;"))
            XCTAssertTrue(html.contains(
                "padding-bottom: calc(78px + env(safe-area-inset-bottom, 0px));"))
        }
        // The reader's 96px foot already cleared it, so it needs no coarse override at all.
        let reader = ReaderPage.html(article: article)
        XCTAssertTrue(reader.contains(
            "padding-bottom: calc(96px + env(safe-area-inset-bottom, 0px));"))
        XCTAssertFalse(reader.contains("padding-top: calc(68px"))
    }

    func testANarrowPointerWindowStillClearsItsTopChrome() {
        // The one case that keeps the chrome at the top: a mouse in a window narrower than
        // the measure breakpoint. 56px clears the 41px the pointer cluster occupies.
        for html in [StartPage.html(appName: "R"), SettingsPage.html(appName: "R")] {
            XCTAssertTrue(html.contains("padding-top: 56px;"))
        }
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

    // MARK: - The collapsing bottom-right chrome

    func testHidingIsKeyedOnViewportSizeAndSizingOnThePointer() {
        // The two questions are separate and were once conflated. *Whether* to hide the
        // controls asks "is there room for them beside the article?" — a narrow desktop
        // window answers that exactly as a phone does, and the distraction is the same
        // whether a finger or a cursor put them there. *How big* to make them asks what is
        // pointing at them, which a window width says nothing about.
        XCTAssertEqual(ReaderChrome.compactViewport, "(max-width: 48rem), (max-height: 30rem)")
        // Height as well as width: a phone in landscape is 844px wide and 390px tall, so a
        // width test alone would leave it with the top cluster eating a fifth of the screen.
        XCTAssertTrue(ReaderChrome.compactViewport.contains("max-height"))
        // Sizing is the union: a tablet is roomy but touched, a narrow window is moused but
        // cramped, and the floating column wants air around it in both.
        XCTAssertEqual(ReaderChrome.comfortableChrome,
                       "(pointer: coarse), " + ReaderChrome.compactViewport)
        // The layout follows the viewport…
        let chrome = ReaderChrome.chromeCSS()
        XCTAssertTrue(chrome.contains("@media \(ReaderChrome.compactViewport) {"))
        XCTAssertFalse(chrome.contains("@media (pointer: coarse) {"))
        // …and the panel's position with it, while what is inside the panel does not.
        let controls = ReaderChrome.controlsCSS()
        XCTAssertTrue(controls.contains("@media \(ReaderChrome.compactViewport) {"))
        XCTAssertTrue(controls.contains("@media (pointer: coarse) {"))
    }

    func testCompactChromeSitsInTheThumbCornerAndCollapses() {
        // Both halves of the report this answers: the top edge is the hardest place on a
        // phone to reach one-handed, and six always-visible buttons over prose compete with
        // the prose.
        let css = ReaderChrome.chromeCSS(collapsible: true)
        XCTAssertTrue(css.contains("bottom: calc(14px + env(safe-area-inset-bottom, 0px));"))
        XCTAssertTrue(css.contains("right: calc(14px + env(safe-area-inset-right, 0px));"))
        // Collapsed is the default, so the first paint is right without waiting for script,
        // and it uses `visibility` so a hidden button leaves the tab order too.
        XCTAssertTrue(css.contains("visibility: hidden; opacity: 0; pointer-events: none;"))
        XCTAssertTrue(css.contains("visibility: visible; opacity: 1; pointer-events: auto;"))
    }

    func testHidingAddressesButtonsByIdFromTheRootAndNotThroughTheTree() {
        // The mechanism this replaced ran through
        // `.reader-chrome[data-collapsible]:not([data-open]) .reader-nav > button` — four
        // links of structure across an ancestor that switched `display` at the media
        // boundary, which is what left buttons visible after a collapse until the next
        // resize. Root attribute to id is two links and no intermediate element.
        let css = ReaderChrome.chromeCSS(collapsible: true)
        for id in ReaderChrome.stackButtonIDs {
            XCTAssertTrue(css.contains("#\(id)"), "\(id) is not addressed by id")
            XCTAssertTrue(css.contains("\(ReaderChrome.chromeOpenRoot) #\(id)"),
                          "\(id) has no reveal rule under the root state")
        }
        // Nothing reaches a button through the cluster elements any more…
        XCTAssertFalse(css.contains(".reader-nav > button"))
        XCTAssertFalse(css.contains(".reader-control > button"))
        // …and no ancestor of a chrome button changes `display` between the two layouts.
        // The declaration, not the word: the stylesheet's own comment says why it is gone.
        XCTAssertFalse(css.contains("display: contents;"))
    }

    func testEveryButtonInTheColumnIsTheSameSquare() {
        // Measured 44x44 for the icon buttons, 47x44 for "Aa" and 45x44 for the toggle: a
        // ragged right edge in a vertical stack, where on a horizontal row the same
        // difference reads as correct. Fixed as ids, because the square has to beat
        // `#readerHomeBtn`'s and `#readerRecentsBtn`'s own padding rules.
        let css = ReaderChrome.chromeCSS()
        for id in ["#readerHomeBtn", "#startSettings", "#readerAa", "#readerRecentsBtn",
                   "#readerHiddenBtn", "#readerMoreBtn", "#readerLessBtn",
                   "#readerChromeToggle"] {
            XCTAssertTrue(css.contains(id), "\(id) is not squared in the column")
        }
        XCTAssertTrue(css.contains("width: 44px; padding: 0;"))
        // And only in the column: a wider "Aa" beside narrower icons is right on a line.
        guard let square = css.range(of: "width: 44px; padding: 0;"),
              let compact = css.range(of: "@media \(ReaderChrome.compactViewport) {",
                                      options: .backwards,
                                      range: css.startIndex..<square.lowerBound) else {
            return XCTFail("the square must sit inside a compact-viewport block")
        }
        XCTAssertLessThan(compact.lowerBound, square.lowerBound)
    }

    func testTheStartPageSettingsButtonTradesItsWordForAnIconInTheColumn() {
        // A text button would be the one wide row in a stack of squares. Both are in the
        // markup and CSS picks one, the same trick the toggle uses — CSS can hide a child,
        // not rewrite one. The button keeps its `aria-label` either way.
        let html = StartPage.html(appName: "R")
        XCTAssertTrue(html.contains("<button id=\"startSettings\" type=\"button\" aria-label=\"Settings\""))
        XCTAssertTrue(html.contains("<span class=\"nav-label\">Settings</span>"))
        XCTAssertTrue(html.contains("class=\"nav-icon\""))
        let css = ReaderChrome.chromeCSS()
        // Roomy first, compact second, or the tie goes the wrong way and the icon never shows.
        guard let roomy = css.range(of: "#startSettings .nav-icon { display: none; }"),
              let column = css.range(of: "#startSettings .nav-icon { display: block; }") else {
            return XCTFail("both halves of the swap must be present")
        }
        XCTAssertLessThan(roomy.lowerBound, column.lowerBound)
    }

    func testCollapsingHidesTheNavSlotAlongsideTheCluster() {
        // Reported: Home stayed on screen after collapsing while the cluster went. The nav
        // slot is a separate element from the controls and the one button present on every
        // page, so any mechanism that reaches buttons structurally can miss it. Naming ids
        // makes that impossible — and this asserts the nav slot's own id specifically.
        let css = ReaderChrome.chromeCSS(collapsible: true)
        XCTAssertTrue(ReaderChrome.stackButtonIDs.contains("readerHomeBtn"))
        XCTAssertTrue(css.contains("#readerHomeBtn"))
        XCTAssertTrue(css.contains("\(ReaderChrome.chromeOpenRoot) #readerHomeBtn"))
    }

    func testTheStackReversesSoHomeLandsNearestTheThumb() {
        // `column` on the wrapper puts the toggle at the foot; `column-reverse` inside sends
        // the nav slot — first in the markup — to the bottom of the stack, directly above
        // it. Verified as rendered geometry in a browser; this pins the two directions that
        // produce it, because getting either backwards silently inverts the column.
        let css = ReaderChrome.chromeCSS(collapsible: true)
        guard let wrapper = css.range(of: ".reader-chrome {"),
              let stack = css.range(of: ".reader-chrome-stack {") else {
            return XCTFail("the chrome column needs both elements")
        }
        XCTAssertLessThan(wrapper.lowerBound, stack.lowerBound)
        XCTAssertTrue(css.contains("display: flex; flex-direction: column; align-items: flex-end;"))
        XCTAssertTrue(css.contains("display: flex; flex-direction: column-reverse; align-items: flex-end;"))
    }

    func testTheWrapperIsAFixedLayerInBothLayoutsRatherThanASwitchingOne() {
        // The wrapper used to be `display: contents` and become `display: flex` at the media
        // boundary — a display change on an ancestor of every chrome button, and the thing
        // the collapse stopped resolving across. It is a fixed layer in both layouts now; in
        // the roomy one its clusters are `position: fixed` to their own corners, so it holds
        // nothing.
        let css = ReaderChrome.chromeCSS(collapsible: true)
        XCTAssertFalse(css.contains("display: contents;"))
        XCTAssertTrue(css.contains(".reader-chrome {\n  position: fixed; z-index: 10;"))
        // Only the clusters change position between layouts, which is the whole difference.
        XCTAssertTrue(css.contains(".reader-nav, .reader-controls {\n    position: static;"))
        // And the toggle is a compact-layout control only.
        XCTAssertTrue(css.contains("#readerChromeToggle { display: none; }"))
    }

    func testOnlyAPageWithSomethingToHideCanCollapse() {
        // A control that reveals one control is a tap for nothing. A page with a single
        // button emits no hiding rules at all, which is what stops the settings and offline
        // pages from tucking away the only control they have.
        for html in [ReaderPage.html(article: article), StartPage.html(appName: "R")] {
            XCTAssertTrue(html.contains("id=\"readerChromeToggle\""))
            XCTAssertTrue(html.contains(ReaderChrome.chromeOpenRoot))
        }
        for html in [SettingsPage.html(appName: "R"),
                     OfflineFallback.html(appName: "R", host: "e.test", kind: .offline)] {
            XCTAssertFalse(html.contains("id=\"readerChromeToggle\""))
            XCTAssertFalse(html.contains(ReaderChrome.chromeOpenRoot))
            XCTAssertFalse(html.contains("visibility: hidden; opacity: 0;"))
        }
    }

    func testTheToggleSaysWhatItDoesToAScreenReader() {
        // It is an icon-only control that owns the whole chrome, so the label and the
        // expanded state are the only things telling a screen reader what it is. The label
        // is swapped by the script; this pins the resting state and the wiring.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("aria-label=\"Show reader controls\""))
        XCTAssertTrue(html.contains("aria-expanded=\"false\""))
        XCTAssertTrue(html.contains("aria-controls=\"readerChromeStack\""))
        XCTAssertTrue(html.contains("id=\"readerChromeStack\""))
        XCTAssertTrue(html.contains("open ? 'Hide reader controls' : 'Show reader controls'"))
    }

    func testOpeningAPopoverCollapsesTheStack() {
        // One thing on screen at a time: the panel fills the space above the toggle, so the
        // column that opened it would only be in the way.
        let html = ReaderPage.html(article: article)
        XCTAssertTrue(html.contains("if (which) { setChromeOpen(false); }"))
        // And the stack dismisses on the same gestures as the popovers.
        XCTAssertTrue(html.contains("if (!e.target.closest('.reader-chrome')) { setChromeOpen(false); }"))
        XCTAssertTrue(html.contains("if (chromeIsOpen()) { setChromeOpen(false); chromeToggle.focus(); }"))
    }
}
