import Foundation

/// `KeyValueStore` over a single JSON object of `String: String` on disk.
///
/// It exists for the Linux host. `DefaultsStore` is the right thing on macOS, but
/// corelibs-Foundation's `UserDefaults` writes wherever its own implementation happens to
/// put a plist — that location is an implementation detail, not a contract, and the state
/// it holds here is the user's settings, recents, hidden phrases and sources. A store the
/// app names itself lands under `$XDG_CONFIG_HOME` where the rest of the desktop keeps its
/// configuration, survives a Foundation change, and can be backed up or edited by hand.
///
/// Nothing about it is platform-specific, which is the point: it is a plain `KeyValueStore`,
/// so it is usable on macOS and directly testable. `ReaderStore` anticipated exactly this
/// substitution — every value it stores is already a JSON string, which is also what lets a
/// whole state document travel in a sync device file (`ReaderKit/Sync`, issue #7).
/// Thread-safe, because `KeyValueStore` requires it: sync reads and writes the store from
/// its own queue while the UI reads it on the main thread. The lock is around the cache,
/// not around the file, which is the same guarantee `UserDefaults` gives — two *processes*
/// sharing one store still need the single-writer discipline `ReaderKit/Sync` uses.
public final class FileStore: KeyValueStore, @unchecked Sendable {
    private let fileURL: URL
    /// Loaded on first access, then authoritative: the file is only ever written by us.
    private var values: [String: String]?
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func string(forKey key: String) -> String? {
        lock.withLock { loaded()[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        let updated: [String: String] = lock.withLock {
            var values = loaded()
            if let value {
                values[key] = value
            } else {
                values.removeValue(forKey: key)
            }
            self.values = values
            return values
        }
        write(updated)
    }

    /// A missing file is an empty store, and so is an unreadable or malformed one — the same
    /// tolerance `ReaderSettings.fromJSON` has, for the same reason: refusing to start over a
    /// damaged preferences file helps nobody, and the next write repairs it.
    private func loaded() -> [String: String] {
        if let values { return values }
        let contents = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        values = contents
        return contents
    }

    private func write(_ values: [String: String]) {
        let encoder = JSONEncoder()
        // Sorted and indented because this is a config file a person may open; stable key
        // order also keeps it diffable when it lands in a dotfiles repo.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // `.atomic` is a write to a sibling temporary file followed by a rename, and this
        // store is one file holding *everything*: a torn write would take the settings, the
        // recents list, the hidden phrases and the sources with it in one go.
        try? data.write(to: fileURL, options: .atomic)
    }
}
