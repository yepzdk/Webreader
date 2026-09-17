import XCTest
@testable import ReaderKit

/// Swiping a sheet away. The handle at the top of a sheet always said "this moves" and only
/// meant "this scrolls"; these pin the gesture that makes the promise true, and the three
/// guards that keep it from stealing gestures that belong to something else.
final class SheetGestureTests: XCTestCase {
    private let js = ReaderChrome.controlsScript(settings: ReaderSettings(),
                                                 thumbnails: .reader,
                                                 hidden: HiddenPhrases([]))
    private let css = ReaderChrome.controlsCSS()

    func testTheGestureExistsOnlyWhereThePanelIsASheet() {
        // Above the breakpoint a panel hangs off its button with the page behind it usable,
        // and dragging a popover off its anchor would mean nothing. Keyed on the same query
        // the sheet CSS is, rather than on the pointer: what makes it a sheet is the
        // viewport, and a narrow desktop window gets the sheet and the gesture with it.
        XCTAssertTrue(js.contains("window.matchMedia('\(ReaderChrome.compactViewport)')"))
        XCTAssertTrue(js.contains("if (drag || !panel || !sheetQuery || !sheetQuery.matches) { return; }"))
    }

    func testTheSheetFollowsTheFingerAndTheScrimFollowsTheSheet() {
        XCTAssertTrue(js.contains("drag.panel.style.transform = 'translateY(' + drag.travel + 'px)';"))
        // The travel is the only thing that says how close the gesture is to dismissing it.
        XCTAssertTrue(js.contains("scrim.style.opacity = String(Math.max(0, 1 - drag.travel / height));"))
        // Animated when it settles or leaves, never while a finger is on it.
        XCTAssertTrue(css.contains("transition: transform \(ReaderChrome.sheetSettle)ms ease;"))
        guard let rule = css.range(of: "#readerHidden[data-dragging] {"),
              let close = css[rule.upperBound...].range(of: "}") else {
            return XCTFail("a dragging sheet has no rule of its own")
        }
        XCTAssertTrue(css[rule.upperBound..<close.lowerBound].contains("transition: none;"))
    }

    func testItLeavesPastTheThresholdOrOnAFlickAndSettlesBackShortOfBoth() {
        XCTAssertTrue(js.contains("gesture.travel > \(ReaderChrome.sheetDismissTravel)"))
        XCTAssertTrue(js.contains("gesture.speed > \(ReaderChrome.sheetFlickSpeed)"))
        XCTAssertTrue(js.contains("dismissSheet(gesture.panel);"))
        XCTAssertTrue(js.contains("resetSheet(gesture.panel);"))
        // A slip of the thumb on a 44px row is not a dismissal, and the threshold has to
        // stay clear of one.
        XCTAssertGreaterThan(ReaderChrome.sheetDismissTravel, ReaderChrome.touchTarget)
    }

    func testTheGestureIsTheHandlesAndTheHandleOptsOutOfPanning() {
        // The defect this exists for, reported from an iPhone: "I can grab the handle and
        // start the drag, but it slips and jumps back". WebKit gave the touch to its own
        // pan recogniser, which cancels the pointer stream a few px in. `preventDefault` on
        // `pointermove` does not stop a scroll there; `touch-action: none` does, and only a
        // real element can carry it — which is why the handle stopped being a `::before`.
        XCTAssertTrue(css.contains("touch-action: none;"))
        XCTAssertTrue(js.contains("var handle = p.panel.querySelector('.sheet-handle');"))
        XCTAssertTrue(js.contains("handle.addEventListener('touchstart'"))
        XCTAssertTrue(js.contains("handle.addEventListener('pointerdown'"))
        // The listener is the handle's, so the sheet is its parent.
        XCTAssertTrue(js.contains("beginDrag(handle.parentElement,"))
        // And the sheet itself keeps its scrolling: only the strip opts out.
        XCTAssertFalse(css.contains("#readerPanel, #readerRecents, #readerHidden {\n            touch-action: none"))
        // Nothing keys off where in the sheet the pointer landed any more.
        XCTAssertFalse(js.contains("panel.scrollTop"))
        XCTAssertFalse(js.contains("fromHandle"))
    }

    func testAnUpwardDragIsHandedBackRatherThanHeldForTheRestOfTheGesture() {
        XCTAssertTrue(js.contains("if (dy < -4) { drag = null; return false; }"))
        XCTAssertTrue(js.contains("if (dy < \(ReaderChrome.sheetDragSlop)) { return false; }"))
    }

    func testDismissalGoesThroughTheSamePlaceEveryOtherDismissalDoes() {
        // One close path: the sheet slides out, then `setOpen(null)` runs — so the panels,
        // the scrim, the buttons' `aria-expanded` and the collapsed column all end up where
        // every other dismissal leaves them. Focus lands where the scrim's own click
        // leaves it, because the button that opened the sheet is behind the column by then.
        XCTAssertTrue(js.contains("setOpen(null);"))
        XCTAssertTrue(js.contains("if (chromeToggle) { chromeToggle.focus(); }"))
        // Asked not to animate: it still goes, it just goes at once — and nothing waits on
        // a transition that will not run.
        XCTAssertTrue(js.contains("if (stillMotion && stillMotion.matches) { done(); return; }"))
        XCTAssertTrue(js.contains("window.setTimeout(done, \(ReaderChrome.sheetSettle));"))
        XCTAssertTrue(css.contains("@media (prefers-reduced-motion: reduce)"))
    }

    func testOpeningASheetClearsWhateverADragLeftOnIt() {
        // A sheet dragged halfway and then closed some other way — Escape, the scrim, its
        // own button — would otherwise open again already pushed down the screen.
        XCTAssertTrue(js.contains("p.panel.style.transform = '';"))
        XCTAssertTrue(js.contains("p.panel.removeAttribute('data-dragging');"))
        XCTAssertTrue(js.contains("if (scrim) { scrim.hidden = !which; scrim.style.opacity = ''; }"))
    }

    func testTheDragSurvivesWhicheverStreamTheEngineGivesIt() {
        // What the iPhone report came down to: on WebKit the pointer stream is synthesised
        // from touches and cancelled the moment the pan recogniser claims the gesture, and
        // `preventDefault` on `pointermove` does not stop a scroll there. So touch events
        // where there is touch — `preventDefault` on a non-passive `touchmove` does stop it
        // — and pointer events everywhere else, for a mouse in a narrow window.
        XCTAssertTrue(js.contains("var touchHost = 'ontouchstart' in window;"))
        XCTAssertTrue(js.contains("document.addEventListener('touchmove', function (e) {"))
        XCTAssertTrue(js.contains("{ passive: false }"))
        XCTAssertTrue(js.contains("e.preventDefault();"))
        // One stream or the other, never both: they describe the same finger, and two
        // handlers would count its travel twice.
        XCTAssertTrue(js.contains("if (touchHost) {"))
        XCTAssertTrue(js.contains("} else {"))
        // Both ends of both streams, so a cancelled gesture cannot leave a sheet mid-drag.
        for ending in ["touchend", "touchcancel", "pointerup", "pointercancel"] {
            XCTAssertTrue(js.contains("document.addEventListener('\(ending)', endDrag);"),
                          "\(ending) does not end the drag")
        }
    }

    func testEverySheetGetsTheGestureNotJustTheAppearanceOne() {
        // Consistency: the three panels look the same, are dismissed the same three ways
        // already, and now move the same way too — which needs the handle in all three
        // markups, not just the one that was reported.
        let page = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                    content: "<p>x</p>"),
                                   history: ReaderHistory())
        for panel in ["readerPanel", "readerRecents", "readerHidden"] {
            guard let open = page.range(of: "id=\"\(panel)\"") else {
                return XCTFail("\(panel) is not in the page")
            }
            let rest = page[open.upperBound...].prefix(200)
            XCTAssertTrue(rest.contains(ReaderChrome.sheetHandle),
                          "\(panel) opens without a grab handle")
        }
        for id in ["#readerPanel", "#readerRecents", "#readerHidden"] {
            XCTAssertTrue(css.contains("\(id)[data-dragging]"), "\(id) has no dragging rule")
        }
    }
}
