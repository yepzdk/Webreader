import XCTest
@testable import ReaderKit

/// The picker that replaced the selection-driven Hide-text button: a mode you turn on, in
/// which a click on the article removes the block under the pointer. The JS is asserted the
/// way every other generated script in this suite is — by the lines that carry the contract.
final class BlockPickerTests: XCTestCase {
    private let js = BlockPicker.js()
    private let css = BlockPicker.css()

    func testNothingListensUntilTheModeIsOn() {
        // The whole reason this replaced the old affordance: while the mode is off the
        // article's selection belongs to the browser, so the listeners are added when the
        // mode is turned on and removed when it is turned off.
        XCTAssertTrue(js.contains("article.addEventListener('pointermove', onMove);"))
        XCTAssertTrue(js.contains("article.removeEventListener('pointermove', onMove);"))
        XCTAssertTrue(js.contains("article.addEventListener('click', onClick, true);"))
        XCTAssertTrue(js.contains("article.removeEventListener('click', onClick, true);"))
        XCTAssertFalse(js.contains("selectionchange"))
        XCTAssertFalse(js.contains("getSelection"))
        // Aiming is not reading: the text stops being selectable only inside the mode.
        XCTAssertTrue(css.contains(":root[data-picking=\"true\"] article {"))
        XCTAssertTrue(css.contains("user-select: none"))
    }

    func testAClickRemovesTheBlockRatherThanFollowingTheLinkInIt() {
        XCTAssertTrue(js.contains("e.preventDefault();"))
        XCTAssertTrue(js.contains("e.stopPropagation();"))
        // Capture, so a link's own handler never sees the click first.
        XCTAssertTrue(js.contains("'click', onClick, true"))
    }

    func testTheCandidateGrowsToTheWrapperAndTakesMediaWithIt() {
        // Pointing at a paragraph inside a wrapper div should take the wrapper, or its
        // margins stay behind as a gap; pointing at a caption or an image inside a figure
        // should take the figure, so the picture goes with its words.
        XCTAssertTrue(js.contains("window.readerNormalize(parent.textContent)"))
        XCTAssertTrue(js.contains("window.readerNormalize(el.textContent)"))
        XCTAssertTrue(js.contains("tag === 'FIGURE' || tag === 'PICTURE' || tag === 'BLOCKQUOTE'"))
        // The definition it depends on: one normalizer, exported by the script the page
        // loads first, rather than a second copy that can drift from the phrase pass.
        let chromeScript = ReaderChrome.controlsScript(settings: ReaderSettings(),
                                                       thumbnails: .reader,
                                                       hidden: HiddenPhrases([]))
        XCTAssertTrue(chromeScript.contains("window.readerNormalize = readerNormalize;"))
        // The same block list the phrase pass matches against, so the two cannot disagree
        // about what counts as a thing rather than part of a sentence.
        XCTAssertTrue(HiddenPhrases.hideScript.contains(BlockPicker.blocks))
        XCTAssertTrue(js.contains(BlockPicker.blocks))
        // And the emptied-wrapper tail, so nothing is left holding the space.
        XCTAssertTrue(js.contains("!parent.textContent.trim() && !parent.querySelector(MEDIA)"))
    }

    func testEveryRemovalIsUndoableAndTellsTheHostEitherWay() {
        // The node is kept with its parent and next sibling, so Undo puts it back where it
        // was rather than at the end.
        XCTAssertTrue(js.contains("removals.push({ node: el, parent: el.parentNode, next: el.nextSibling });"))
        XCTAssertTrue(js.contains("entry.parent.insertBefore(entry.node, entry.next);"))
        // One post for both directions: the cached copy is rewritten from what is left.
        XCTAssertTrue(js.contains("readerPost('readerHideBlock', article.innerHTML);"))
        XCTAssertEqual(js.components(separatedBy: "readerPost('readerHideBlock'").count - 1, 1)
    }

    func testTheModeIsReachableAndLeavableWithoutAPointer() {
        // A keyboard has nothing to hover with, so the article's own blocks take focus
        // while the mode is on and Enter removes the focused one.
        XCTAssertTrue(js.contains("child.setAttribute('tabindex', '0');"))
        XCTAssertTrue(js.contains("child.removeAttribute('tabindex');"))
        XCTAssertTrue(js.contains("if (e.key !== 'Enter' && e.key !== ' ') { return; }"))
        XCTAssertTrue(js.contains("if (e.key === 'Escape') { setPicking(false); returnFocus(); return; }"))
        // Leaving puts focus back on something that has a box: the button that started the
        // mode, or the burger it collapses behind.
        XCTAssertTrue(js.contains("if (toggle.getClientRects().length) { toggle.focus(); return; }"))
    }

    func testTheButtonSaysWhetherTheModeIsOn() {
        // `aria-pressed`, not `aria-expanded`: nothing opens. What changes is what the next
        // click on the article means, which is exactly what a pressed control is for.
        XCTAssertTrue(js.contains("toggle.setAttribute('aria-pressed', String(on));"))
        let chrome = ReaderChrome.controlsCSS()
        XCTAssertTrue(chrome.contains("#\(BlockPicker.buttonID)[aria-pressed=\"true\"] {"))
    }

    func testTheBarUsesHouseTokensAndNoEmoji() {
        // Design convention: house tokens, subtle radii, one accent, and a line icon rather
        // than a glyph — the button's own icon lives in the chrome markup.
        XCTAssertTrue(css.contains("background: var(--bg);"))
        XCTAssertTrue(css.contains("border: 1px solid var(--border);"))
        XCTAssertTrue(css.contains("border-radius: 8px;"))
        XCTAssertTrue(css.contains("outline: 2px solid var(--accent);"))
        let hasEmoji = (css + js).unicodeScalars.contains { scalar in
            (0x1F300...0x1FAFF).contains(scalar.value) || (0x2600...0x27BF).contains(scalar.value)
        }
        XCTAssertFalse(hasEmoji, "the picker must not contain emoji")
    }

    func testTheBarStaysBelowTheChromeAndTakesTheEdgeFromIt() {
        // An open popover must never be crossed by something floating over the article, so
        // the bar sits under `.reader-controls` (10) and the progress line (9). The chrome
        // goes away while the mode is on: at a phone's width a floating bar and a 48px
        // toggle cannot both have the bottom edge, and the bar carries the way out.
        guard let range = css.range(of: "z-index: ") else {
            return XCTFail("the bar must pin its own z-index")
        }
        XCTAssertLessThan(Int(css[range.upperBound...].prefix { $0.isNumber }) ?? .max, 9)
        XCTAssertTrue(css.contains("bottom: calc(var(--safe-bottom) + 14px);"))
        XCTAssertTrue(css.contains(":root[data-picking=\"true\"] .reader-chrome { display: none; }"))
    }

    func testTheBarReachesTheTouchFloor() {
        XCTAssertTrue(css.contains("min-height: \(ReaderChrome.touchTarget)px;"))
        XCTAssertTrue(css.contains(Platform.macOS.sansStack))
        XCTAssertTrue(BlockPicker.css(platform: .linux).contains(Platform.linux.sansStack))
    }

    func testItInterpolatesNothingFromAPage() {
        // The escaping discipline: no article text is baked into the script — what it reads,
        // it reads from the DOM at click time.
        XCTAssertFalse(js.lowercased().contains("</script"))
        XCTAssertFalse(HiddenPhrases.defaults.contains { js.contains($0) })
    }

    func testItSelfDisablesWhereThereIsNoArticle() {
        XCTAssertTrue(js.contains("if (!article || !toggle) { return; }"))
    }
}
