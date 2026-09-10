import XCTest
@testable import ReaderKit

/// The vocabulary a host that is not written in Swift reads.
///
/// Kotlin matches these `kind` strings and reads these keys by name, and no compiler can see
/// across that boundary: a rename would build on both sides and degrade at runtime to a logged
/// "unknown command" on a phone. So they are pinned here — changing one has to change this
/// file, which is the reminder to change `MainActivity.execute` in the same commit.
final class ReaderCommandJSONTests: XCTestCase {
    private let url = URL(string: "https://example.test/a")!

    func testEveryCommandCarriesTheKindItsHostMatches() {
        let commands: [ReaderCommand] = [
            .load(url), .show(html: "<p></p>", baseURL: url), .evaluate("noop()"),
            .extract(url: url, script: "s"), .reject, .openExternally(url),
            .presentSyncSetup, .fetchSuggestions, .resolveSource(url),
        ]
        XCTAssertEqual(commands.json.map { $0["kind"] as? String },
                       ["load", "show", "evaluate", "extract", "reject", "openExternally",
                        "presentSyncSetup", "fetchSuggestions", "resolveSource"])
    }

    func testThePayloadKeysAreTheOnesTheHostReads() {
        XCTAssertEqual(ReaderCommand.load(url).json?["url"] as? String, url.absoluteString)
        let show = ReaderCommand.show(html: "<p>Hi</p>", baseURL: url).json
        XCTAssertEqual(show?["html"] as? String, "<p>Hi</p>")
        XCTAssertEqual(show?["baseUrl"] as? String, url.absoluteString)
        let extract = ReaderCommand.extract(url: url, script: "run()").json
        XCTAssertEqual(extract?["url"] as? String, url.absoluteString)
        XCTAssertEqual(extract?["script"] as? String, "run()")
        XCTAssertEqual(ReaderCommand.evaluate("push()").json?["script"] as? String, "push()")
        XCTAssertEqual(ReaderCommand.openExternally(url).json?["url"] as? String,
                       url.absoluteString)
        XCTAssertEqual(ReaderCommand.resolveSource(url).json?["url"] as? String,
                       url.absoluteString)
    }

    func testOurOwnPagesSayTheyHaveNoBaseURL() {
        // Serialised as `null` rather than left out: the host reads the key for "none", and an
        // absent key would only be the same answer by accident. Asserted through
        // `JSONSerialization` because that is what actually crosses the boundary.
        let json = ReaderCommand.show(html: "<p></p>", baseURL: nil).json
        let data = try? JSONSerialization.data(withJSONObject: json ?? [:], options: [])
        XCTAssertNotNil(data, "an own page's show command has to survive serialisation")
        XCTAssertTrue(String(decoding: data ?? Data(), as: UTF8.self)
            .contains("\"baseUrl\":null"))
    }

    func testAnEmptyScriptNeverCrossesTheBoundary() {
        // The session's way of saying "nothing to push". Sending it would cost a hop and a web
        // view round trip to run nothing.
        XCTAssertNil(ReaderCommand.evaluate("").json)
        XCTAssertEqual([ReaderCommand.evaluate(""), .reject].json.count, 1)
    }

    func testAPostedBodyArrivesAsOneOfThreeShapes() {
        XCTAssertEqual(ReaderSession.MessageBody(json: "text"), .text("text"))
        XCTAssertEqual(ReaderSession.MessageBody(json: ["a", "b"]), .list(["a", "b"]))
        // The font size is the only number any page posts, and it has to stay one.
        XCTAssertEqual(ReaderSession.MessageBody(json: ["fontSize": 22, "theme": "dark"]),
                       .object(["fontSize": .number(22), "theme": .text("dark")]))
        // Anything else is a host bug: guessing at it is how a shape reaches a handler that
        // was written for another.
        XCTAssertNil(ReaderSession.MessageBody(json: nil))
        XCTAssertNil(ReaderSession.MessageBody(json: 3.5))
    }
}
