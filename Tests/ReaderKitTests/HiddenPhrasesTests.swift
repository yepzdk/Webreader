import XCTest
@testable import ReaderKit

// The phrase list's rules: seeding, bounds, dedupe, storage, and safe embedding in a script.
// The DOM matching itself (`hideScript`) has no DOM here and is hand-verified.
final class HiddenPhrasesTests: XCTestCase {
    func testNeverStoredOrGarbageMeansDefaults() {
        XCTAssertEqual(HiddenPhrases.fromJSON(nil), HiddenPhrases())
        XCTAssertEqual(HiddenPhrases.fromJSON("{nope"), HiddenPhrases())
        XCTAssertEqual(HiddenPhrases().phrases, HiddenPhrases.defaults)
        XCTAssertTrue(HiddenPhrases.defaults.contains("Artiklen fortsætter efter annoncen"))
    }

    func testEmptiedListStaysEmpty() {
        // The user removed everything; that must not reseed the defaults on next read.
        XCTAssertEqual(HiddenPhrases.fromJSON("[]").phrases, [])
    }

    func testAddCollapsesWhitespaceAndGoesFirst() {
        var list = HiddenPhrases([])
        XCTAssertTrue(list.add("  Læs \n  også  "))
        XCTAssertEqual(list.phrases, ["Læs også"])
        XCTAssertTrue(list.add("Annonce"))
        XCTAssertEqual(list.phrases, ["Annonce", "Læs også"])
    }

    func testAddRejectsEmptyOversizedAndDuplicates() {
        var list = HiddenPhrases(["Annonce"])
        XCTAssertFalse(list.add("   "))
        XCTAssertFalse(list.add(String(repeating: "x", count: HiddenPhrases.maxLength + 1)))
        // Same phrase, different case/spacing/trailing punctuation.
        XCTAssertFalse(list.add("ANNONCE."))
        XCTAssertFalse(list.add("annonce:"))
        XCTAssertEqual(list.phrases, ["Annonce"])
    }

    func testCapIsAppliedOnAddAndRead() {
        var list = HiddenPhrases([])
        for i in 0..<(HiddenPhrases.limit + 5) { list.add("phrase \(i)") }
        XCTAssertEqual(list.phrases.count, HiddenPhrases.limit)
        XCTAssertEqual(list.phrases.first, "phrase \(HiddenPhrases.limit + 4)")

        let oversized = (0..<(HiddenPhrases.limit + 5)).map { "p\($0)" }
        let data = try! JSONSerialization.data(withJSONObject: oversized)
        let decoded = HiddenPhrases.fromJSON(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(decoded.phrases.count, HiddenPhrases.limit)
    }

    func testRemoveAndJSONRoundTrip() {
        var list = HiddenPhrases(["A", "B", "C"])
        list.remove("B")
        XCTAssertEqual(list.phrases, ["A", "C"])
        XCTAssertEqual(HiddenPhrases.fromJSON(list.json), list)
        // Non-string rows are skipped, not fatal.
        XCTAssertEqual(HiddenPhrases.fromJSON(#"["A", 7, null, "C"]"#).phrases, ["A", "C"])
    }

    func testScriptLiteralCannotCloseTheScriptTag() {
        let list = HiddenPhrases(["</script><script>alert(1)</script>", "say \"hi\""])
        let literal = list.scriptLiteral
        XCTAssertFalse(literal.contains("</"))
        XCTAssertTrue(literal.contains("<\\/script>"))
        XCTAssertTrue(literal.contains("\\\"hi\\\""))
    }

    func testHideScriptReportsWhatItRemoved() {
        // The badge and the popover grouping depend on the return shape.
        XCTAssertTrue(HiddenPhrases.hideScript.contains("var result = { total: 0, hits: {} };"))
        XCTAssertTrue(HiddenPhrases.hideScript.contains("result.hits[key] = (result.hits[key] || 0) + 1;"))
        XCTAssertTrue(HiddenPhrases.hideScript.contains("return result;"))
    }

    // MARK: - The in-page hide affordance

    func testHideAffordancePostsTheLiveSelectionToTheHost() {
        let js = HiddenPhrases.hideAffordanceJS()
        // The handler name is a contract with the host; renaming it here alone gates the
        // feature shut silently.
        XCTAssertTrue(js.contains("readerPost('readerHide', text);"))
        // The posted string is the one captured when the selection was made — the same
        // string the retired Edit-menu item sent, so `add`'s normalization and whole-block
        // matching are unchanged. Read at selection time, not at press time: pressing a
        // button collapses the selection on every platform, and the `preventDefault` trick
        // that used to paper over that has no touch equivalent.
        XCTAssertTrue(js.contains("pending = window.getSelection().toString();"))
        XCTAssertTrue(js.contains("var text = pending;"))
        XCTAssertFalse(js.contains("mousedown"))
        // `readerPost` is the only host API it touches, which is why this ports to any host
        // without a platform branch here: the transport itself is the only thing that
        // differs per platform, and it is chosen once in `ReaderChrome.transportScript`.
        // The guard that used to sit at this call site moved in there with it.
        XCTAssertFalse(js.contains("window.webkit."))
        XCTAssertEqual(js.components(separatedBy: "readerPost(").count - 1, 1)
    }

    func testHideAffordanceTracksAndDismissesTheSelection() {
        let js = HiddenPhrases.hideAffordanceJS()
        XCTAssertTrue(js.contains("document.addEventListener('selectionchange', update);"))
        XCTAssertTrue(js.contains("window.addEventListener('scroll', hide, true);"))
        XCTAssertTrue(js.contains("if (e.key === 'Escape') { hide(); }"))
        // Positioned off the selection's own rect, and only when it's inside the article.
        XCTAssertTrue(js.contains("range.getBoundingClientRect()"))
        XCTAssertTrue(js.contains("article.contains(range.commonAncestorContainer)"))
        // Confirmed with the shared toast, like the other page-side actions.
        XCTAssertTrue(js.contains("window.readerToast("))
    }

    func testHideAffordanceIsPointerNeutralAndDodgesTheSystemCallout() {
        let js = HiddenPhrases.hideAffordanceJS()
        // One event for mouse, touch and pen — `mouseup` never fires for a touch selection.
        XCTAssertTrue(js.contains("document.addEventListener('pointerup',"))
        XCTAssertFalse(js.contains("mouseup"))
        // iOS draws Copy / Look Up directly above a selection, so on a coarse pointer the
        // button prefers the space below it and only falls back above.
        XCTAssertTrue(js.contains("window.matchMedia('(pointer: coarse)').matches"))
        XCTAssertTrue(js.contains("var top = coarse ? below : above;"))
        // Clamped into the viewport whichever side it lands on.
        XCTAssertTrue(js.contains("Math.min(Math.max(8, top), Math.max(8, floor))"))
    }

    func testHideAffordanceStaysBelowTheReaderControls() {
        // An open popover must never be crossed by a button floating over the article, so
        // the affordance sits under `.reader-controls` (z-index 10).
        let css = HiddenPhrases.hideAffordanceCSS()
        guard let range = css.range(of: "z-index: ") else {
            return XCTFail("the affordance must pin its own z-index")
        }
        let value = css[range.upperBound...].prefix { $0.isNumber }
        XCTAssertLessThan(Int(value) ?? .max, 10)
    }

    func testHideAffordanceUsesHouseTokensAndNoEmoji() {
        // Design convention: one accent color, subtle radii, an inline SVG line icon and a
        // text label — never an emoji.
        let css = HiddenPhrases.hideAffordanceCSS()
        let js = HiddenPhrases.hideAffordanceJS()
        // Outlined like every control the accent touches: the colour is the border
        // and the label, never a fill under a label.
        XCTAssertTrue(css.contains("border: 1px solid var(--accent);"))
        XCTAssertTrue(css.contains("color: var(--accent);"))
        XCTAssertTrue(css.contains("border-radius: 6px;"))
        XCTAssertTrue(js.contains("stroke=\"currentColor\""))
        XCTAssertTrue(js.contains("<span>Hide text</span>"))
        let hasEmoji = (css + js).unicodeScalars.contains { scalar in
            (0x1F300...0x1FAFF).contains(scalar.value) || (0x2600...0x27BF).contains(scalar.value)
        }
        XCTAssertFalse(hasEmoji, "the hide affordance must not contain emoji")
    }

    func testHideAffordanceInterpolatesNothingFromAPage() {
        // The escaping discipline: a learned phrase reaches a <script> only as
        // `scriptLiteral`. The affordance interpolates no page text at all — it reads the
        // selection at runtime — so it can carry no `</script` however hostile the article.
        let js = HiddenPhrases.hideAffordanceJS()
        XCTAssertFalse(js.lowercased().contains("</script"))
        // No phrase text is baked in: the selection is read from the DOM at click time,
        // and a stored phrase still reaches a page only through `scriptLiteral`.
        XCTAssertFalse(HiddenPhrases.defaults.contains { js.contains($0) })
    }

    func testHideAffordanceFollowsTheHostPlatformsSansStack() {
        // Chrome, not article type: the button takes the platform's UI stack, and the
        // no-argument form stays the macOS one for the AppKit host.
        XCTAssertTrue(HiddenPhrases.hideAffordanceCSS().contains(Platform.macOS.sansStack))
        XCTAssertTrue(HiddenPhrases.hideAffordanceCSS(platform: .linux).contains(Platform.linux.sansStack))
    }

    func testStoreSeedsDefaultsAndPersistsEdits() {
        let store = MemoryStore()
        XCTAssertEqual(ReaderStore.hiddenPhrases(store: store), HiddenPhrases())
        var list = ReaderStore.hiddenPhrases(store: store)
        list.add("Reklame")
        ReaderStore.setHiddenPhrases(list, store: store)
        XCTAssertEqual(ReaderStore.hiddenPhrases(store: store).phrases.first, "Reklame")
        // Resetting appearance is about presentation; learned phrases are user data.
        ReaderStore.resetAppearance(store: store)
        XCTAssertEqual(ReaderStore.hiddenPhrases(store: store), list)
    }
}
