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
        /// The article's lead image (`Article.image`), for the start page's thumbnails (#25).
        /// Optional because a page need not name one — and because every row stored before
        /// #25 has none. Kept here rather than in `ArticleCache`, which is evictable: a row
        /// whose cache file had been pruned would silently lose its thumbnail.
        public let image: String?

        public init(title: String, url: String, image: String? = nil) {
            self.title = title
            self.url = url
            self.image = image
        }
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
    public mutating func record(title: String, url: String, image: String? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else { return }
        entries.removeAll { $0.url == url }
        entries.insert(Entry(title: title, url: url, image: image), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// The list as a JSON array string — the storage format. The reader page does NOT
    /// consume this: its rows are rendered (and escaped) in Swift from `entries`, so no
    /// history data reaches the page as script.
    public var json: String {
        // The image key is omitted rather than written as null when there is none, so a blob
        // from before #25 round-trips byte-identically.
        let array: [[String: String]] = entries.map { entry in
            var row = ["title": entry.title, "url": entry.url]
            if let image = entry.image { row["image"] = image }
            return row
        }
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
            // Read after the guard, so a row with no image decodes as a row without one
            // rather than being dropped.
            return Entry(title: title, url: url, image: row["image"] as? String)
        }
        if history.entries.count > limit {
            history.entries.removeLast(history.entries.count - limit)
        }
        return history
    }
}
