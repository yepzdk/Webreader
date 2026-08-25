import Foundation
import ReaderKit

/// One-time import of reader state from the webwrap-generated WebReader app this project
/// replaced (bundle id `dk.yepz.webwrap.webreader`): appearance settings, the recents list,
/// and page zoom. The JSON formats are identical; only the keys and the defaults domain
/// changed. Site logins live in that app's WebKit store and aren't carried over.
enum LegacyImport {
    static let legacySuite = "dk.yepz.webwrap.webreader"

    private static let keyMap = [
        ("webwrap.reader.settings", ReaderStore.Key.settings),
        ("webwrap.reader.history", ReaderStore.Key.history),
        ("webwrap.zoom", ReaderStore.Key.zoom),
    ]

    static func run(into store: KeyValueStore, legacy: UserDefaults? = UserDefaults(suiteName: legacySuite)) {
        guard store.string(forKey: ReaderStore.Key.legacyImported) == nil, let legacy else { return }
        for (old, new) in keyMap where store.string(forKey: new) == nil {
            store.set(legacy.string(forKey: old), forKey: new)
        }
        store.set("1", forKey: ReaderStore.Key.legacyImported)
    }
}
