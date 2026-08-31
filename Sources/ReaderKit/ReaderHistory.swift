import Foundation

/// The reader's recents list: the articles this app has rendered in reader mode, newest
/// first. Persisted per app as a JSON string (like `ReaderSettings`) and surfaced by the
/// reader page's list popover, whose rows navigate back to an article.
///
/// Pure — no WebKit, no UserDefaults — so the cap/dedupe/decode rules are unit-testable;
/// the host injects the store and does the navigating.
public struct ReaderHistory: Equatable, Sendable {
    /// One read article. The URL is the extraction source (`readerSourceURL`), so
    /// re-opening it re-enters the reader the same way the original visit did.
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let url: String
        /// When the article was read, in seconds since 1970 — the ordering key when two
        /// devices' lists are merged (`merging`). `nil` in rows written before sync
        /// existed and in hand-written JSON: they sort last, and a `clearedAt` tombstone
        /// drops them, because anything untimestamped predates every clear.
        public let readAt: Double?

        public init(title: String, url: String, readAt: Double? = nil) {
            self.title = title
            self.url = url
            self.readAt = readAt
        }
    }

    /// How many entries are kept. A recents list, not an archive — the oldest fall off.
    public static let limit = 30

    public var entries: [Entry] = []

    /// When "Clear history" last ran, in seconds since 1970. Kept after the list is empty
    /// so a device that syncs later merges the clear instead of restoring its own copy of
    /// the list — an empty list alone is indistinguishable from a device that has read
    /// nothing yet.
    public var clearedAt: Double?

    public init() {}

    public init(clearedAt: Double) { self.clearedAt = Timestamp.stamp(clearedAt) }

    /// Records an article as the newest entry.
    ///
    /// Deduped by URL: re-reading an article moves it to the front (with its latest
    /// title, which can change as a page is edited) instead of adding a second row.
    /// Entries without a title or URL are dropped — an untitled row is unnavigable
    /// noise in the panel.
    public mutating func record(title: String, url: String,
                                at readAt: Double = Timestamp.now()) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else { return }
        entries.removeAll { $0.url == url }
        entries.insert(Entry(title: title, url: url, readAt: Timestamp.stamp(readAt)), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// This list merged with another device's, newest first. Pure, so the rule set is
    /// unit-tested rather than inferred from behaviour in the field:
    ///
    /// - the newer `clearedAt` wins, and every entry read at or before it is dropped —
    ///   that's what stops a device that was offline during a "Clear history" from
    ///   restoring the list on its next sync;
    /// - entries are unioned by URL, keeping the copy with the newer `readAt` and hence
    ///   its title; a tie (or two untimestamped rows) keeps this list's copy;
    /// - untimestamped rows sort after every timestamped one, in this list's order then
    ///   the other's, so a pre-sync list keeps the order it had;
    /// - the cap is re-applied, so merging can never grow the panel.
    public func merging(_ other: ReaderHistory) -> ReaderHistory {
        var merged = ReaderHistory()
        merged.clearedAt = [clearedAt, other.clearedAt].compactMap { $0 }.max()

        // First appearance fixes the order of rows that can't be compared by time.
        var order: [String: Int] = [:]
        var best: [String: Entry] = [:]
        for entry in entries + other.entries {
            if order[entry.url] == nil { order[entry.url] = order.count }
            guard let kept = best[entry.url] else { best[entry.url] = entry; continue }
            if (entry.readAt ?? -.greatestFiniteMagnitude) > (kept.readAt ?? -.greatestFiniteMagnitude) {
                best[entry.url] = entry
            }
        }

        let kept = best.values.filter { entry in
            guard let clearedAt = merged.clearedAt else { return true }
            guard let readAt = entry.readAt else { return false }
            return readAt > clearedAt
        }
        merged.entries = kept.sorted { a, b in
            let left = a.readAt ?? -.greatestFiniteMagnitude
            let right = b.readAt ?? -.greatestFiniteMagnitude
            if left != right { return left > right }
            return (order[a.url] ?? 0) < (order[b.url] ?? 0)
        }
        if merged.entries.count > Self.limit {
            merged.entries.removeLast(merged.entries.count - Self.limit)
        }
        return merged
    }

    /// The storage format as a `JSONSerialization` object, so a sync device file can nest
    /// it without round-tripping through a string.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "v": 1,
            "entries": entries.map { entry -> [String: Any] in
                var row: [String: Any] = ["title": entry.title, "url": entry.url]
                if let readAt = entry.readAt { row["readAt"] = readAt }
                return row
            },
        ]
        if let clearedAt { object["clearedAt"] = clearedAt }
        return object
    }

    /// The list as a JSON string — the storage format. The reader page does NOT
    /// consume this: its rows are rendered (and escaped) in Swift from `entries`, so no
    /// history data reaches the page as script.
    public var json: String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject,
                                                    options: [.sortedKeys])
        else { return "{\"entries\":[],\"v\":1}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tolerant decode of a `JSONSerialization` object: the current object form, or the
    /// bare array written before sync existed (still in every existing installation's
    /// defaults, and in what `LegacyImport` carries over). Garbage means an empty list,
    /// never an error, and individual malformed rows are skipped rather than poisoning
    /// the whole list. The cap is re-applied on read so a hand-edited or older oversized
    /// blob can't grow the panel.
    public static func decode(_ value: Any?) -> ReaderHistory {
        var history = ReaderHistory()
        let rows: [[String: Any]]
        switch value {
        case let array as [[String: Any]]:
            rows = array
        case let object as [String: Any]:
            rows = object["entries"] as? [[String: Any]] ?? []
            history.clearedAt = Timestamp.decode(object["clearedAt"])
        default:
            return history
        }
        history.entries = rows.compactMap { row in
            guard let title = row["title"] as? String, !title.isEmpty,
                  let url = row["url"] as? String, !url.isEmpty else { return nil }
            return Entry(title: title, url: url, readAt: Timestamp.decode(row["readAt"]))
        }
        if history.entries.count > limit {
            history.entries.removeLast(history.entries.count - limit)
        }
        return history
    }

    /// Decodes stored JSON with the same tolerance as `decode`.
    public static func fromJSON(_ string: String?) -> ReaderHistory {
        guard let string, let data = string.data(using: .utf8) else { return ReaderHistory() }
        return decode(try? JSONSerialization.jsonObject(with: data))
    }
}
