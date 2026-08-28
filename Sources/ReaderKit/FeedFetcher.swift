import Foundation

/// Fetches the suggestion sources. The only networking in the app outside the web view, so
/// it's deliberately small: a plain `URLSession`, a short in-memory TTL so returning to the
/// start page doesn't re-hit every feed, and failures that resolve to "no items" rather than
/// errors — a suggestion list is never worth an error message.
///
/// Cancellation is the caller's: `items(for:)` runs inside the host's `Task`, which is
/// cancelled when the start page goes away.
public actor FeedFetcher {
    private let session: URLSession
    private let ttl: TimeInterval
    private var cache: [String: (items: [FeedItem], fetched: Date)] = [:]
    /// Injected so tests (and a future iOS host) don't depend on the wall clock.
    private let now: () -> Date

    public init(session: URLSession = .shared, ttl: TimeInterval = 600, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.ttl = ttl
        self.now = now
    }

    /// Every source's items, fetched concurrently. A source that fails, times out or isn't a
    /// feed any more contributes nothing.
    public func items(for sources: [FeedSource]) async -> [FeedItem] {
        guard !sources.isEmpty else { return [] }
        var fresh: [FeedItem] = []
        var stale: [FeedSource] = []
        for source in sources {
            if let entry = cache[source.url], now().timeIntervalSince(entry.fetched) < ttl {
                fresh += entry.items
            } else {
                stale.append(source)
            }
        }
        guard !stale.isEmpty else { return fresh }
        let fetched = await withTaskGroup(of: (String, [FeedItem]).self) { group in
            for source in stale {
                group.addTask { [self] in
                    guard let url = URL(string: source.url) else { return (source.url, []) }
                    let parsed = try? await self.feed(at: url)
                    return (source.url, parsed?.items ?? [])
                }
            }
            var results: [(String, [FeedItem])] = []
            for await result in group { results.append(result) }
            return results
        }
        let stamp = now()
        for (url, items) in fetched {
            // Cached even when empty, so a broken source isn't retried on every visit.
            cache[url] = (items, stamp)
            fresh += items
        }
        return fresh
    }

    /// Turns a URL the user typed into a source: a feed URL becomes one directly, a page URL
    /// is scanned for an advertised feed. Throws `Failure.notAFeed` when neither works.
    public func resolve(_ url: URL) async throws -> FeedSource {
        let (data, _) = try await load(url)
        if let parsed = Feed.parse(data, from: url) {
            return FeedSource(url: url.absoluteString, title: parsed.title, language: parsed.language)
        }
        let html = String(decoding: data, as: UTF8.self)
        for candidate in Feed.discover(inHTML: html, base: url).prefix(3) {
            guard let (feedData, _) = try? await load(candidate),
                  let parsed = Feed.parse(feedData, from: candidate) else { continue }
            return FeedSource(url: candidate.absoluteString, title: parsed.title, language: parsed.language)
        }
        throw Failure.notAFeed
    }

    public enum Failure: Error { case notAFeed }

    private func feed(at url: URL) async throws -> Feed.Parsed? {
        let (data, _) = try await load(url)
        return Feed.parse(data, from: url)
    }

    private func load(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("WebReader", forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }
}
