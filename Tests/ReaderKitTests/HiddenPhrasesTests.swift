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

    // MARK: - The picker that replaced the selection affordance

    func testTheSelectionDrivenAffordanceIsGone() {
        // What it was and why it went: it repositioned a floating button on every
        // `selectionchange` during a drag, and on touch it could only try to dodge the
        // system's own Copy / Look Up callout. Nothing on the reader page listens to the
        // selection any more, which is what "leave the browser's selection alone" means.
        let page = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                    content: "<p>Body</p>"))
        XCTAssertFalse(page.contains("selectionchange"))
        XCTAssertFalse(page.contains("readerHideBtn"))
        XCTAssertFalse(page.contains("getSelection().toString()"))
    }

    func testTheHideEverywhereRouteStillPostsTheSamePhraseMessage() {
        // The phrase list did not change, only the gesture that feeds it: the picker offers
        // the text of the block it just removed, and the message is the one the host has
        // always handled.
        let js = BlockPicker.js()
        XCTAssertTrue(js.contains("readerPost('readerHide', text);"))
        XCTAssertTrue(js.contains("window.readerToast("))
        // Offered for a leaf block short enough to be a label, and not for a container,
        // whose `textContent` is its children run together rather than a phrase.
        XCTAssertTrue(js.contains("!el.querySelector(BLOCKS) && text.length"))
        XCTAssertTrue(js.contains("text.length <= \(BlockPicker.phraseOffer)"))
        XCTAssertLessThan(BlockPicker.phraseOffer, HiddenPhrases.maxLength)
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
