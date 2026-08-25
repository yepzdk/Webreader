import Foundation

/// The reader's recents list: the articles this app has rendered in reader mode, newest
/// first. Persisted per app as a JSON string (like `ReaderSettings`) and surfaced by the
/// reader page's list popover, whose rows navigate back to an article.
///
/// Pure — no WebKit, no UserDefaults — so the cap/dedupe/decode rules are unit-testable;
/// the host injects the store and does the navigating.
public struct ReaderHistory: Equatable {
    /// One read article. The URL is the extraction source (`readerSourceURL`), so
    /// re-opening it re-enters the reader the same way the original visit did.
    public struct Entry: Equatable {
        public let title: String
        public let url: String
    }

    /// How many entries are kept. A recents list, not an archive — the oldest fall off.
    public static let limit = 30

    public var entries: [Entry] = []

    public init() {}

    /// Records an article as the newest entry.
    ///
    /// Deduped by URL: re-reading an article moves it to the front (with its latest
    /// title, which can change as a page is edited) instead of adding a second row.
    /// Entries without a title or URL are dropped — an untitled row is unnavigable
    /// noise in the panel.
    public mutating func record(title: String, url: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else { return }
        entries.removeAll { $0.url == url }
        entries.insert(Entry(title: title, url: url), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// The list as a JSON array string — the storage format. The reader page does NOT
    /// consume this: its rows are rendered (and escaped) in Swift from `entries`, so no
    /// history data reaches the page as script.
    public var json: String {
        let array = entries.map { ["title": $0.title, "url": $0.url] }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes stored JSON with the same tolerance as `ReaderSettings.fromJSON`:
    /// nil/garbage means an empty list, never an error, and individual malformed rows
    /// are skipped rather than poisoning the whole list. The cap is re-applied on read
    /// so a hand-edited or older oversized blob can't grow the panel.
    public static func fromJSON(_ string: String?) -> ReaderHistory {
        guard let string, let data = string.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ReaderHistory() }
        var history = ReaderHistory()
        history.entries = array.compactMap { row in
            guard let title = row["title"] as? String, !title.isEmpty,
                  let url = row["url"] as? String, !url.isEmpty else { return nil }
            return Entry(title: title, url: url)
        }
        if history.entries.count > limit {
            history.entries.removeLast(history.entries.count - limit)
        }
        return history
    }
}
