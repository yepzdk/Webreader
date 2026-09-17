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
        XCTAssertTrue(js.contains("if (drag || !sheetQuery || !sheetQuery.matches) { return; }"))
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

    func testADragBelowTheHandleBelongsToTheListUntilTheListHasNowhereLeft() {
        // The first guard: a flick through a long list must scroll it, not throw it away.
        XCTAssertTrue(js.contains("if (!fromHandle && panel.scrollTop > 0) { return; }"))
        XCTAssertTrue(js.contains("e.clientY - panel.getBoundingClientRect().top <= \(ReaderChrome.sheetGrabZone)"))
        // The zone has to cover the panel's own 12px of padding, the 4px grabber and its
        // 8px margin, or the one place the gesture is advertised would not answer.
        XCTAssertGreaterThanOrEqual(ReaderChrome.sheetGrabZone, 24)
    }

    func testAnUpwardDragIsHandedBackRatherThanHeldForTheRestOfTheGesture() {
        // The second guard. Without it, starting upward and reversing would drag the sheet
        // from wherever the finger happened to be by then.
        XCTAssertTrue(js.contains("if (dy < -4) { drag = null; return; }"))
        XCTAssertTrue(js.contains("if (dy < \(ReaderChrome.sheetDragSlop)) { return; }"))
    }

    func testAGestureThatMovedTheSheetDoesNotAlsoPressWhatItStartedOn() {
        // The third guard, and the one a user would notice: a drag that begins on a stepper
        // and settles back must not also step. Capture phase, so the click reaches neither
        // the control nor the outside-click dismissal.
        XCTAssertTrue(js.contains("swallowClick = true;"))
        XCTAssertTrue(js.contains("if (!swallowClick) { return; }"))
        XCTAssertTrue(js.contains("}, true);"))
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

    func testTheMoveListenerCanStopTheScrollersItCompetesWith() {
        // Passive listeners cannot `preventDefault`, and without that the sheet's own
        // scroller and the article behind it take the rest of the gesture.
        XCTAssertTrue(js.contains("document.addEventListener('pointermove', onSheetMove, { passive: false });"))
        XCTAssertTrue(js.contains("e.preventDefault();"))
        // Pointer capture, so a finger that leaves the sheet mid-drag still owns it.
        XCTAssertTrue(js.contains("drag.panel.setPointerCapture(drag.id)"))
        // And the gesture ends on a cancel as well as on a release.
        XCTAssertTrue(js.contains("document.addEventListener('pointercancel', onSheetUp);"))
    }

    func testEverySheetGetsTheGestureNotJustTheAppearanceOne() {
        // Consistency: the three panels look the same, are dismissed the same three ways
        // already, and now move the same way too.
        XCTAssertTrue(js.contains("p.panel.addEventListener('pointerdown', onSheetDown);"))
        for id in ["#readerPanel", "#readerRecents", "#readerHidden"] {
            XCTAssertTrue(css.contains("\(id)[data-dragging]"), "\(id) has no dragging rule")
        }
    }
}
