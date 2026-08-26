import Foundation

/// The last extraction of every recent article, one JSON file each, so a recents row opens
/// from disk and a failed load can fall back to it. A cache, not a library: it never grows
/// past the recents list (`prune(keeping:)` runs on every history write), write failures are
/// ignored, and anything unreadable is a miss. The body stored is the post-filter one;
/// phrases learned later are still applied live by the reader page on load.
public struct ArticleCache {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// What's on disk: the URL travels with the article so a read can verify the key.
    private struct Entry: Codable {
        let url: String
        let article: Article
    }

    /// The filename stem for a URL — FNV-1a 64 as 16 hex digits. Stable across launches
    /// (unlike `Hasher`, which is randomly seeded per process).
    // ponytail: FNV rather than SHA-256 keeps ReaderKit off CryptoKit; a collision is a
    // miss (the stored URL is checked on read), never a wrong article.
    public static func key(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func file(for url: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: url) + ".json")
    }

    /// nil for a miss — including a corrupt file or one whose stored URL isn't this one.
    public func article(for url: URL) -> Article? {
        guard let data = try? Data(contentsOf: file(for: url)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.url == url.absoluteString else { return nil }
        return entry.article
    }

    /// Writes (or replaces) the article for `url`, creating the directory on first use.
    public func store(_ article: Article, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Entry(url: url.absoluteString, article: article))
        else { return }
        try? data.write(to: file(for: url), options: .atomic)
    }

    /// Deletes every file that isn't one of `urls` — the recents list — so the cache is
    /// exactly what the panel can reopen. An empty list empties the cache.
    public func prune(keeping urls: [String]) {
        let keep = Set(urls.compactMap(URL.init(string:)).map { Self.key(for: $0) + ".json" })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
