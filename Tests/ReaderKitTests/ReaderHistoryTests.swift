import XCTest
@testable import ReaderKit

// Tests for the reader's recents list: the cap/dedupe rules and tolerant JSON decode.
// The panel's rendering is covered in ReaderTests; navigating a row is WebKit
// orchestration, hand-verified per repo convention.

final class ReaderHistoryTests: XCTestCase {
    func testRecordsNewestFirst() {
        var history = ReaderHistory()
        history.record(title: "First", url: "https://example.com/1")
        history.record(title: "Second", url: "https://example.com/2")
        XCTAssertEqual(history.entries.map(\.title), ["Second", "First"])
    }

    func testRereadingMovesToFrontWithoutDuplicating() {
        var history = ReaderHistory()
        history.record(title: "A", url: "https://example.com/a")
        history.record(title: "B", url: "https://example.com/b")
        // Same URL, retitled upstream since the first read.
        history.record(title: "A (updated)", url: "https://example.com/a")
        XCTAssertEqual(history.entries.map(\.title), ["A (updated)", "B"])
    }

    func testCapDropsTheOldest() {
        var history = ReaderHistory()
        for i in 1...(ReaderHistory.limit + 5) {
            history.record(title: "Article \(i)", url: "https://example.com/\(i)")
        }
        XCTAssertEqual(history.entries.count, ReaderHistory.limit)
        XCTAssertEqual(history.entries.first?.title, "Article \(ReaderHistory.limit + 5)")
        // The first five have fallen off the end.
        XCTAssertEqual(history.entries.last?.title, "Article 6")
    }

    func testUnusableEntriesAreDropped() {
        var history = ReaderHistory()
        history.record(title: "", url: "https://example.com/x")
        history.record(title: "   ", url: "https://example.com/y")
        history.record(title: "No URL", url: "")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testTitleIsTrimmed() {
        var history = ReaderHistory()
        history.record(title: "  Spaced  ", url: "https://example.com/s")
        XCTAssertEqual(history.entries.first?.title, "Spaced")
    }

    func testJSONRoundTrip() {
        var history = ReaderHistory()
        history.record(title: "One", url: "https://example.com/1")
        history.record(title: "Two & \"quoted\"", url: "https://example.com/2")
        XCTAssertEqual(ReaderHistory.fromJSON(history.json), history)
    }

    func testGarbageDecodesToEmpty() {
        // Same tolerance as ReaderSettings: nothing here is ever an error.
        XCTAssertTrue(ReaderHistory.fromJSON(nil).entries.isEmpty)
        XCTAssertTrue(ReaderHistory.fromJSON("").entries.isEmpty)
        XCTAssertTrue(ReaderHistory.fromJSON("not json").entries.isEmpty)
        XCTAssertTrue(ReaderHistory.fromJSON(#"{"title":"an object, not an array"}"#).entries.isEmpty)
        XCTAssertTrue(ReaderHistory.fromJSON("[]").entries.isEmpty)
    }

    func testMalformedRowsAreSkippedNotFatal() {
        let json = """
        [{"title":"Good","url":"https://example.com/good"},
         {"title":"Missing URL"},
         {"url":"https://example.com/untitled"},
         {"title":"","url":"https://example.com/empty"},
         {"title":"Also good","url":"https://example.com/also"}]
        """
        XCTAssertEqual(ReaderHistory.fromJSON(json).entries.map(\.title), ["Good", "Also good"])
    }

    func testOversizedStoredListIsCappedOnRead() {
        // A hand-edited or older blob can't grow the panel past the cap.
        let rows = (1...(ReaderHistory.limit + 10))
            .map { #"{"title":"A\#($0)","url":"https://example.com/\#($0)"}"# }
            .joined(separator: ",")
        XCTAssertEqual(ReaderHistory.fromJSON("[\(rows)]").entries.count, ReaderHistory.limit)
    }

    func testRecordStampsWhenTheArticleWasRead() {
        var history = ReaderHistory()
        history.record(title: "Read", url: "https://example.com/r", at: 1_756_000_000)
        XCTAssertEqual(history.entries.first?.readAt, 1_756_000_000)
        // Re-reading restamps, so the merge treats it as the newer copy.
        history.record(title: "Read", url: "https://example.com/r", at: 1_756_000_900)
        XCTAssertEqual(history.entries.first?.readAt, 1_756_000_900)
    }

    func testTimestampsAndTombstoneSurviveTheRoundTrip() {
        var history = ReaderHistory(clearedAt: 1_755_000_000)
        history.record(title: "One", url: "https://example.com/1", at: 1_756_000_000)
        XCTAssertEqual(ReaderHistory.fromJSON(history.json), history)
    }

    func testTheListWrittenBeforeSyncStillDecodes() {
        // What every existing installation has in its defaults: a bare array, no
        // timestamps. Those rows sort last in a merge and a tombstone drops them.
        let legacy = #"[{"title":"Old","url":"https://example.com/old"}]"#
        let history = ReaderHistory.fromJSON(legacy)
        XCTAssertEqual(history.entries.map(\.title), ["Old"])
        XCTAssertNil(history.entries.first?.readAt)
        XCTAssertNil(history.clearedAt)
    }

    // MARK: - Lead image (#25)

    func testTheImageRoundTripsAndIsOptional() {
        var history = ReaderHistory()
        history.record(title: "With", url: "https://x.test/a", image: "https://x.test/a.jpg")
        history.record(title: "Without", url: "https://x.test/b")
        let decoded = ReaderHistory.fromJSON(history.json)
        XCTAssertEqual(decoded.entries.map(\.image), [nil, "https://x.test/a.jpg"])
    }

    func testARowWithNoImageOmitsTheKeyEntirely() {
        // Not written as null: a list stored before #25 has to round-trip unchanged, or every
        // launch rewrites the blob (and, once sync lands, re-uploads it).
        var history = ReaderHistory()
        history.record(title: "Plain", url: "https://x.test/b")
        XCTAssertFalse(history.json.contains("image"))
        XCTAssertEqual(ReaderHistory.fromJSON(history.json).json, history.json)
    }

    func testALegacyBlobDecodesWithNoImage() {
        // Rows written before #25 have no image key. They must decode as rows without an
        // image, never be skipped as malformed.
        let decoded = ReaderHistory.fromJSON(
            "[{\"title\":\"Old\",\"url\":\"https://x.test/old\"}]")
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertNil(decoded.entries[0].image)
        XCTAssertEqual(decoded.entries[0].title, "Old")
    }

    func testRecentsTrimsAndCanDropTheArticleOnScreen() {
        var history = ReaderHistory()
        for index in 1...8 { history.record(title: "A\(index)", url: "https://x.test/\(index)") }
        // Newest first, so 8 is the top row.
        let five = history.recents(limit: 5)
        XCTAssertEqual(five.entries.map(\.title), ["A8", "A7", "A6", "A5", "A4"])
        // Excluding takes effect before the cap, so the panel still gets five rows.
        let excluded = history.recents(limit: 5, excluding: "https://x.test/8")
        XCTAssertEqual(excluded.entries.map(\.title), ["A7", "A6", "A5", "A4", "A3"])
    }

    func testRecentsDropsTheArticleOnScreenUnderAnySpellingOfItsAddress() {
        // The row is excluded because it is the article you are looking at, and "the same
        // article" cannot mean "the same string": the feed link that reached this page and
        // the address the site redirected to are both spellings of one piece of writing.
        var history = ReaderHistory()
        history.record(title: "On screen", url: "https://www.dr.dk/nyheder/x")
        history.record(title: "Another", url: "https://dr.dk/nyheder/y")
        let excluded = history.recents(limit: 5, excluding: "https://dr.dk/nyheder/x/")
        XCTAssertEqual(excluded.entries.map(\.title), ["Another"])
    }

    func testRecentsKeepsTheLeadImage() {
        // The popover's thumbnails hang off it, and every other thumbnail test reaches
        // `recentsRows` directly — so this hop is where an image could go missing unnoticed.
        var history = ReaderHistory()
        history.record(title: "Illustrated", url: "https://x.test/a", image: "https://x.test/l.jpg")
        XCTAssertEqual(history.recents(limit: 5).entries.first?.image, "https://x.test/l.jpg")
    }

    func testRecentsAsksForNothingOrLess() {
        // `prefix` traps on a negative length, and this is library API on a type whose every
        // other boundary is defensive.
        var history = ReaderHistory()
        for index in 1...3 { history.record(title: "A\(index)", url: "https://x.test/\(index)") }
        XCTAssertTrue(history.recents(limit: 0).entries.isEmpty)
        XCTAssertTrue(history.recents(limit: -1).entries.isEmpty)
        // More than there is, and more than the stored cap, both just give everything.
        XCTAssertEqual(history.recents(limit: 99).entries.count, 3)
    }

    func testRecentsDropsEveryCopyOfAnExcludedURL() {
        // `record` dedupes, but `fromJSON` does not — a hand-edited blob can hold duplicates.
        let decoded = ReaderHistory.fromJSON("""
            [{"title":"One","url":"https://x.test/dup"},{"title":"Two","url":"https://x.test/dup"}]
            """)
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertTrue(decoded.recents(limit: 5, excluding: "https://x.test/dup").entries.isEmpty)
    }

    func testRecentsIsHappyWithLessThanItAsksFor() {
        var history = ReaderHistory()
        history.record(title: "Only", url: "https://x.test/only")
        XCTAssertEqual(history.recents(limit: 5).entries.count, 1)
        XCTAssertTrue(history.recents(limit: 5, excluding: "https://x.test/only").entries.isEmpty)
        XCTAssertTrue(ReaderHistory().recents(limit: 5).entries.isEmpty)
    }
}
