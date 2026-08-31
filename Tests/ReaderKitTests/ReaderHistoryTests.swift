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
}
