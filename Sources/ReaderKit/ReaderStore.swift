import Foundation

/// The minimal read/write surface the reader's persisted state needs from a key-value
/// store. `DefaultsStore` wraps `UserDefaults`; tests pass an in-memory implementation.
/// Kept to strings so a whole state document is one value a sync device file can carry.
///
/// `Sendable`, because sync reads and writes the store from its own queue while the UI
/// reads it on the main thread: an implementation has to be safe from both.
public protocol KeyValueStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    /// `nil` removes the key.
    func set(_ value: String?, forKey key: String)
}

/// `KeyValueStore` over `UserDefaults` (the app's standard suite by default).
///
/// Unchecked: `UserDefaults` is documented as thread-safe but isn't annotated `Sendable`,
/// and this class adds no state of its own beyond the suite it was handed.
public final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// `KeyValueStore` in memory.
///
/// Not a test double any more, though the tests are still its heaviest user: the Android
/// facade seeds one from the state Kotlin passes in, runs whatever was asked for, and hands
/// the changed keys back. Nothing on that path has a `UserDefaults` or a file to write, and
/// a store that keeps its own copy is what makes the call a pure function.
///
/// Locked because sync writes it from its own queue while the UI reads it, which is the
/// whole reason `KeyValueStore` is `Sendable`. Unchecked, like `FileStore`: the lock is what
/// makes it safe, and the compiler cannot see that from a mutable stored property.
public final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(_ values: [String: String] = [:]) {
        storage = values
    }

    /// A snapshot, for a caller that needs every key at once — the Android facade returning
    /// what a call changed, or a test asserting that nothing did.
    public var values: [String: String] { lock.withLock { storage } }

    public func string(forKey key: String) -> String? { lock.withLock { storage[key] } }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock {
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
    }
}

/// Reads and writes the reader's persisted state: appearance settings, the recents list,
/// and page zoom. (De)serialization lives in `ReaderSettings`/`ReaderHistory`; this layer
/// only owns the keys and the zoom bounds. Pure — the store is injected.
public enum ReaderStore {
    public enum Key {
        public static let settings = "reader.settings"
        public static let history = "reader.history"
        public static let zoom = "reader.zoom"
        public static let hiddenPhrases = "reader.hiddenPhrases"
        public static let suggestions = "reader.suggestions"
        public static let topics = "reader.topics"
        /// When settings were last changed on this device — the tiebreaker when another
        /// device's file carries different appearance settings. Kept beside the settings
        /// rather than inside them so the reader page's script seed stays unchanged.
        public static let settingsUpdatedAt = "reader.settings.updatedAt"
        /// Marker set once the one-time import from the webwrap-generated app has run.
        public static let legacyImported = "reader.legacyImported"

        // Sync: the folder every instance exchanges device files through, this device's
        // identity within it, and when it last synced (shown in the Sync sheet).
        /// Bookmark data (base64) for the chosen folder — it survives a rename or move.
        public static let syncFolder = "reader.sync.folder"
        /// The folder's path when it was chosen. Display only; the bookmark is the truth.
        public static let syncFolderPath = "reader.sync.folderPath"
        /// This installation's device id — the name of the one file it writes.
        public static let syncDeviceID = "reader.sync.deviceID"
        public static let syncLastSuccess = "reader.sync.lastSuccess"
    }

    // MARK: - Appearance

    public static func settings(store: KeyValueStore) -> ReaderSettings {
        ReaderSettings.fromJSON(store.string(forKey: Key.settings))
    }

    public static func setSettings(_ settings: ReaderSettings, store: KeyValueStore,
                                   at now: Double = Timestamp.now()) {
        store.set(settings.json, forKey: Key.settings)
        store.set(String(Timestamp.stamp(now)), forKey: Key.settingsUpdatedAt)
    }

    /// When settings were last written here; 0 when they never were, so any device that
    /// has touched them wins the merge.
    public static func settingsUpdatedAt(store: KeyValueStore) -> Double {
        Timestamp.stamp(Double(store.string(forKey: Key.settingsUpdatedAt) ?? "") ?? 0)
    }

    /// Reverts appearance settings and zoom to stock. NOT the history: it's user data, not
    /// a presentation default, and this action offers no undo — clearing it lives behind
    /// its own affordance in the recents panel.
    ///
    /// The two thumbnail switches survive for the same reason. They stopped being appearance
    /// when they left the Aa popover for the settings page's own "Article images" section
    /// (#33): one of their states means "fetch no images from publishers", and a menu item
    /// called Reset Reader Appearance has no business turning that back on.
    ///
    /// The reset is stamped like any other settings write, so it propagates to the other
    /// devices instead of being overwritten by their older settings on the next sync.
    public static func resetAppearance(store: KeyValueStore,
                                       at now: Double = Timestamp.now()) {
        let kept = settings(store: store)
        var stock = ReaderSettings()
        stock.startPageThumbnails = kept.startPageThumbnails
        stock.readerThumbnails = kept.readerThumbnails
        setSettings(stock, store: store, at: now)
        store.set(nil, forKey: Key.zoom)
    }

    // MARK: - History

    public static func history(store: KeyValueStore) -> ReaderHistory {
        ReaderHistory.fromJSON(store.string(forKey: Key.history))
    }

    public static func setHistory(_ history: ReaderHistory, store: KeyValueStore) {
        store.set(history.json, forKey: Key.history)
    }

    /// Clears the recents list, leaving the tombstone that makes the clear win over
    /// another device's copy of the list on the next sync.
    public static func clearHistory(store: KeyValueStore,
                                    at now: Double = Timestamp.now()) {
        setHistory(ReaderHistory(clearedAt: now), store: store)
    }

    // MARK: - Hidden phrases

    /// Never stored → the defaults (see `HiddenPhrases.fromJSON`). User data like history:
    /// `resetAppearance` leaves it alone.
    public static func hiddenPhrases(store: KeyValueStore) -> HiddenPhrases {
        HiddenPhrases.fromJSON(store.string(forKey: Key.hiddenPhrases))
    }

    public static func setHiddenPhrases(_ phrases: HiddenPhrases, store: KeyValueStore) {
        store.set(phrases.json, forKey: Key.hiddenPhrases)
    }

    // MARK: - Suggestions

    /// Never stored → the shipped source (see `SuggestionSettings.fromJSON`). User data like
    /// history and hidden phrases: `resetAppearance` leaves it alone.
    public static func suggestions(store: KeyValueStore) -> SuggestionSettings {
        SuggestionSettings.fromJSON(store.string(forKey: Key.suggestions))
    }

    public static func setSuggestions(_ settings: SuggestionSettings, store: KeyValueStore) {
        store.set(settings.json, forKey: Key.suggestions)
    }

    /// Never stored → no preferences. User data like the rest: `resetAppearance` leaves it.
    public static func topics(store: KeyValueStore) -> TopicPreferences {
        TopicPreferences.fromJSON(store.string(forKey: Key.topics))
    }

    public static func setTopics(_ topics: TopicPreferences, store: KeyValueStore) {
        store.set(topics.json, forKey: Key.topics)
    }

    // MARK: - Page zoom

    /// The supported page-zoom bounds and the step the menu actions move by.
    public static let zoomRange = 0.5...3.0
    public static let zoomStep = 0.1

    public static func clampZoom(_ value: Double) -> Double {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The persisted page zoom: 1.0 when never set or garbled, clamped otherwise.
    public static func zoom(store: KeyValueStore) -> Double {
        guard let raw = store.string(forKey: Key.zoom), let value = Double(raw) else { return 1.0 }
        return clampZoom(value)
    }

    public static func setZoom(_ value: Double, store: KeyValueStore) {
        store.set(String(clampZoom(value)), forKey: Key.zoom)
    }
}
