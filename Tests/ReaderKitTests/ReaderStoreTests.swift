import XCTest
@testable import ReaderKit

/// In-memory `KeyValueStore` standing in for `UserDefaults`.
final class MemoryStore: KeyValueStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}

final class ReaderStoreTests: XCTestCase {
    func testZoomDefaultsToOneWhenUnsetOrGarbled() {
        let store = MemoryStore()
        XCTAssertEqual(ReaderStore.zoom(store: store), 1.0)
        store.set("not a number", forKey: ReaderStore.Key.zoom)
        XCTAssertEqual(ReaderStore.zoom(store: store), 1.0)
    }

    func testZoomRoundTripsAndClamps() {
        let store = MemoryStore()
        ReaderStore.setZoom(1.3, store: store)
        XCTAssertEqual(ReaderStore.zoom(store: store), 1.3)
        ReaderStore.setZoom(99, store: store)
        XCTAssertEqual(ReaderStore.zoom(store: store), ReaderStore.zoomRange.upperBound)
        XCTAssertEqual(ReaderStore.clampZoom(0.01), ReaderStore.zoomRange.lowerBound)
    }

    func testSettingsAndHistoryRoundTrip() {
        let store = MemoryStore()
        XCTAssertEqual(ReaderStore.settings(store: store), ReaderSettings())
        XCTAssertEqual(ReaderStore.history(store: store), ReaderHistory())

        var settings = ReaderSettings()
        settings.theme = .sepia
        settings.fontSize = 20
        ReaderStore.setSettings(settings, store: store)
        var history = ReaderHistory()
        history.record(title: "A", url: "https://a.test/x")
        ReaderStore.setHistory(history, store: store)

        XCTAssertEqual(ReaderStore.settings(store: store), settings)
        XCTAssertEqual(ReaderStore.history(store: store), history)
    }

    func testSuggestionsRoundTrip() {
        let store = MemoryStore()
        // Unset means the shipped source, not an empty list.
        XCTAssertEqual(ReaderStore.suggestions(store: store).sources, SuggestionSettings.defaults)

        var suggestions = SuggestionSettings(sources: [])
        suggestions.add(FeedSource(url: "https://a.test/rss", title: "A", language: "en"))
        suggestions.languages = ["en"]
        ReaderStore.setSuggestions(suggestions, store: store)
        XCTAssertEqual(ReaderStore.suggestions(store: store), suggestions)
    }

    func testResetAppearanceClearsSettingsAndZoomButKeepsUserData() {
        let store = MemoryStore()
        var settings = ReaderSettings()
        settings.theme = .black
        ReaderStore.setSettings(settings, store: store)
        ReaderStore.setZoom(1.5, store: store)
        var history = ReaderHistory()
        history.record(title: "A", url: "https://a.test/x")
        ReaderStore.setHistory(history, store: store)
        // An emptied source list is a deliberate choice; a reset must not resurrect wallnot.
        ReaderStore.setSuggestions(SuggestionSettings(sources: []), store: store)

        ReaderStore.resetAppearance(store: store)

        XCTAssertEqual(ReaderStore.settings(store: store), ReaderSettings())
        XCTAssertEqual(ReaderStore.zoom(store: store), 1.0)
        XCTAssertEqual(ReaderStore.history(store: store), history)
        XCTAssertTrue(ReaderStore.suggestions(store: store).sources.isEmpty)
    }
}
