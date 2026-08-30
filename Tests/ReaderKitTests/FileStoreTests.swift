import XCTest
@testable import ReaderKit

// The JSON-file-backed `KeyValueStore` the Linux host persists into: round trip, durability
// across instances, and the two ways a file can be unusable (absent, garbage) both meaning
// "empty store" rather than an error.
final class FileStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        // Not created up front: the first write must create it.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileStoreTests-\(UUID().uuidString)")
        fileURL = directory.appendingPathComponent("nested").appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsAndOverwrites() {
        let store = FileStore(fileURL: fileURL)
        XCTAssertNil(store.string(forKey: "a"))
        store.set("one", forKey: "a")
        XCTAssertEqual(store.string(forKey: "a"), "one")
        store.set("two", forKey: "a")
        XCTAssertEqual(store.string(forKey: "a"), "two")
        XCTAssertNil(store.string(forKey: "b"))
    }

    func testNilRemovesTheKey() {
        let store = FileStore(fileURL: fileURL)
        store.set("one", forKey: "a")
        store.set("keep", forKey: "b")
        store.set(nil, forKey: "a")
        XCTAssertNil(store.string(forKey: "a"))
        XCTAssertEqual(FileStore(fileURL: fileURL).string(forKey: "a"), nil)
        XCTAssertEqual(FileStore(fileURL: fileURL).string(forKey: "b"), "keep")
    }

    func testPersistsAcrossInstancesAndCreatesTheDirectory() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let store = FileStore(fileURL: fileURL)
        store.set("value", forKey: "key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(FileStore(fileURL: fileURL).string(forKey: "key"), "value")
    }

    func testMissingFileIsAnEmptyStore() {
        XCTAssertNil(FileStore(fileURL: fileURL).string(forKey: ReaderStore.Key.settings))
        // Reading must not conjure the file — an untouched install has no config.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptFileIsAnEmptyStoreAndIsRepairedByTheNextWrite() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: fileURL)
        let store = FileStore(fileURL: fileURL)
        XCTAssertNil(store.string(forKey: "a"))
        store.set("one", forKey: "a")
        XCTAssertEqual(FileStore(fileURL: fileURL).string(forKey: "a"), "one")
    }

    func testWellFormedJSONOfTheWrongShapeIsAlsoEmpty() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"a": 1}"#.utf8).write(to: fileURL)
        XCTAssertNil(FileStore(fileURL: fileURL).string(forKey: "a"))
    }

    // The store is only ever asked for these, and each value is a JSON blob of its own —
    // quotes, braces and non-ASCII all have to survive the trip through the outer object.
    func testEveryReaderStoreKeyRoundTrips() {
        let store = FileStore(fileURL: fileURL)
        var settings = ReaderSettings()
        settings.theme = .sepia
        ReaderStore.setSettings(settings, store: store)
        var history = ReaderHistory()
        history.record(title: "Vindmøller i Nordsøen", url: "https://a.test/x")
        ReaderStore.setHistory(history, store: store)
        ReaderStore.setZoom(1.3, store: store)
        var phrases = HiddenPhrases()
        phrases.add("Annonce: læs mere")
        ReaderStore.setHiddenPhrases(phrases, store: store)
        var suggestions = SuggestionSettings(sources: [])
        suggestions.add(FeedSource(url: "https://a.test/rss", title: "A", language: "da"))
        ReaderStore.setSuggestions(suggestions, store: store)
        var topics = TopicPreferences()
        topics.prefer("Vindmøller i Nordsøen")
        ReaderStore.setTopics(topics, store: store)
        store.set("1", forKey: ReaderStore.Key.legacyImported)

        let reopened = FileStore(fileURL: fileURL)
        XCTAssertEqual(ReaderStore.settings(store: reopened), settings)
        XCTAssertEqual(ReaderStore.history(store: reopened), history)
        XCTAssertEqual(ReaderStore.zoom(store: reopened), 1.3)
        XCTAssertEqual(ReaderStore.hiddenPhrases(store: reopened), phrases)
        XCTAssertEqual(ReaderStore.suggestions(store: reopened), suggestions)
        XCTAssertEqual(ReaderStore.topics(store: reopened), topics)
        XCTAssertEqual(reopened.string(forKey: ReaderStore.Key.legacyImported), "1")
    }
}
