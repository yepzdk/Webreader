import Foundation

/// The minimal read/write surface the reader's persisted state needs from a key-value
/// store. `DefaultsStore` wraps `UserDefaults`; tests pass an in-memory implementation.
/// Kept to strings so the same shape fits `NSUbiquitousKeyValueStore` when sync lands.
public protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    /// `nil` removes the key.
    func set(_ value: String?, forKey key: String)
}

/// `KeyValueStore` over `UserDefaults` (the app's standard suite by default).
public final class DefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
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
        /// Marker set once the one-time import from the webwrap-generated app has run.
        public static let legacyImported = "reader.legacyImported"
    }

    // MARK: - Appearance

    public static func settings(store: KeyValueStore) -> ReaderSettings {
        ReaderSettings.fromJSON(store.string(forKey: Key.settings))
    }

    public static func setSettings(_ settings: ReaderSettings, store: KeyValueStore) {
        store.set(settings.json, forKey: Key.settings)
    }

    /// Reverts appearance settings and zoom to stock. NOT the history: it's user data, not
    /// a presentation default, and this action offers no undo — clearing it lives behind
    /// its own affordance in the recents panel.
    public static func resetAppearance(store: KeyValueStore) {
        store.set(nil, forKey: Key.settings)
        store.set(nil, forKey: Key.zoom)
    }

    // MARK: - History

    public static func history(store: KeyValueStore) -> ReaderHistory {
        ReaderHistory.fromJSON(store.string(forKey: Key.history))
    }

    public static func setHistory(_ history: ReaderHistory, store: KeyValueStore) {
        store.set(history.json, forKey: Key.history)
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
