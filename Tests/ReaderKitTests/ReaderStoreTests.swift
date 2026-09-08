import XCTest
@testable import ReaderKit

// `MemoryStore` is `ReaderKit`'s own now — the Android facade needs one too.

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
        var topics = TopicPreferences()
        topics.prefer("Vindmøller i Nordsøen")
        ReaderStore.setTopics(topics, store: store)

        ReaderStore.resetAppearance(store: store)

        XCTAssertEqual(ReaderStore.settings(store: store), ReaderSettings())
        XCTAssertEqual(ReaderStore.zoom(store: store), 1.0)
        XCTAssertEqual(ReaderStore.history(store: store), history)
        XCTAssertTrue(ReaderStore.suggestions(store: store).sources.isEmpty)
        XCTAssertEqual(ReaderStore.topics(store: store), topics)
    }

    func testResetAppearanceKeepsWhatTheSettingsPageOwns() {
        // Reset Reader Appearance is about the Aa popover. The article-image switches and the
        // start page's section order are not appearance — they live on the settings page —
        // and one of the switches means "fetch no images from publishers".
        let store = MemoryStore()
        var settings = ReaderSettings()
        settings.theme = .black
        settings.startPageThumbnails = .off
        settings.readerThumbnails = .off
        settings.startPageOrder = .suggestionsFirst
        ReaderStore.setSettings(settings, store: store)

        ReaderStore.resetAppearance(store: store)

        let reset = ReaderStore.settings(store: store)
        XCTAssertEqual(reset.theme, .auto, "what the popover owns does go back to stock")
        XCTAssertEqual(reset.startPageThumbnails, .off)
        XCTAssertEqual(reset.readerThumbnails, .off)
        XCTAssertEqual(reset.startPageOrder, .suggestionsFirst)
    }

    func testTopicPreferencesRoundTrip() {
        let store = MemoryStore()
        XCTAssertTrue(ReaderStore.topics(store: store).weights.isEmpty)
        var topics = TopicPreferences()
        topics.avoid("Superligaen fodbold")
        ReaderStore.setTopics(topics, store: store)
        XCTAssertEqual(ReaderStore.topics(store: store), topics)
    }
}
