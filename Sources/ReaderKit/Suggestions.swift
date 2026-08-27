import Foundation

/// Where suggested articles come from: a feed the user has added (or the shipped default).
/// `title` is the feed's own channel title, resolved once when the source is added, so the
/// settings list can name a source without re-fetching it.
public struct FeedSource: Equatable, Codable {
    public let url: String
    public let title: String
    /// The feed's declared language (`<language>` / `xml:lang`), lowercased to its base code
    /// ("da", "en"). nil when the feed doesn't say — such a source is never filtered out.
    public let language: String?

    public init(url: String, title: String, language: String?) {
        self.url = url
        self.title = title
        self.language = language
    }

    /// The host, for the settings row's second line.
    public var host: String { URL(string: url)?.host ?? url }
}

/// The user's suggestion sources and language filter. Seeded with `defaults` the first time
/// it's read and plain user data afterwards — like `HiddenPhrases`, removing the shipped
/// source sticks, and `ReaderStore.resetAppearance` leaves this alone.
public struct SuggestionSettings: Equatable {
    /// One shipped source, so the start page can suggest something before anything has been
    /// read. wallnot.dk is a non-commercial Danish aggregator of paywall-free articles;
    /// removable like any other row.
    public static let defaults = [
        FeedSource(url: "https://wallnot.dk/rss", title: "Wallnot", language: "da"),
    ]

    /// A reading app, not a feed reader — the list is a handful of sources, not a library.
    public static let limit = 20

    public var sources: [FeedSource]
    /// Which languages may be suggested. nil = no filter (the initial state); a set filters
    /// items whose feed declares a language, and items with no declared language always pass.
    public var languages: Set<String>?

    public init(sources: [FeedSource] = SuggestionSettings.defaults, languages: Set<String>? = nil) {
        self.sources = sources
        self.languages = languages
    }

    /// Adds a resolved source. Returns false — nothing stored — when the feed URL is already
    /// in the list or the cap is reached, so the host can report it.
    @discardableResult
    public mutating func add(_ source: FeedSource) -> Bool {
        guard !source.url.isEmpty, sources.count < Self.limit,
              !sources.contains(where: { $0.url == source.url }) else { return false }
        sources.append(source)
        return true
    }

    public mutating func remove(url: String) {
        sources.removeAll { $0.url == url }
    }

    /// The languages the current sources can actually produce — the checkboxes on the
    /// settings page. Sources that declare no language contribute nothing here (they're
    /// never filtered, so there'd be nothing to toggle).
    public var availableLanguages: [String] {
        Set(sources.compactMap(\.language)).sorted()
    }

    public var json: String {
        var dict: [String: Any] = [
            "sources": sources.map { source -> [String: Any] in
                var row: [String: Any] = ["url": source.url, "title": source.title]
                if let language = source.language { row["language"] = language }
                return row
            },
        ]
        if let languages { dict["languages"] = languages.sorted() }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil (never stored) → the defaults. Anything stored is taken as-is, so a user who
    /// removed every source keeps an empty list. Malformed rows are skipped, never fatal.
    public static func fromJSON(_ string: String?) -> SuggestionSettings {
        guard let string, let data = string.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = dict["sources"] as? [[String: Any]]
        else { return SuggestionSettings() }
        var settings = SuggestionSettings(sources: [])
        settings.sources = rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return FeedSource(url: url,
                              title: (row["title"] as? String) ?? url,
                              language: row["language"] as? String)
        }
        if settings.sources.count > limit { settings.sources.removeLast(settings.sources.count - limit) }
        if let languages = dict["languages"] as? [String] {
            settings.languages = Set(languages)
        }
        return settings
    }
}

/// One candidate article from a feed.
public struct FeedItem: Equatable {
    public let title: String
    public let url: String
    /// The feed's channel title. Kept for provenance, but the start page's second line is
    /// the article's own host: an aggregator's channel title ("Nyeste artikler fra
    /// wallnot.dk") says nothing about who wrote the piece, and the host does.
    public let source: String
    public let language: String?
    public let date: Date?

    /// The outlet the row names: the article's own host, minus a leading "www.".
    public var host: String {
        let host = URL(string: url)?.host ?? source
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public init(title: String, url: String, source: String, language: String? = nil, date: Date? = nil) {
        self.title = title
        self.url = url
        self.source = source
        self.language = language
        self.date = date
    }
}

/// Parsing feeds and finding them in a page. Pure — the fetching lives in `FeedFetcher`.
public enum Feed {
    public struct Parsed: Equatable {
        public let title: String
        public let language: String?
        public let items: [FeedItem]
    }

    /// Parses RSS 2.0 or Atom. nil when the data isn't a feed (an HTML page, an error body),
    /// which is how `FeedFetcher.resolve` tells a feed URL from a page URL.
    public static func parse(_ data: Data, from url: URL) -> Parsed? {
        let parser = FeedParser(feedURL: url)
        guard parser.parse(data) else { return nil }
        return Parsed(title: parser.channelTitle.isEmpty ? (url.host ?? url.absoluteString) : parser.channelTitle,
                      language: parser.channelLanguage.map(baseLanguage),
                      items: parser.items)
    }

    /// The base language code: "da-DK" → "da". Feeds spell this inconsistently.
    static func baseLanguage(_ raw: String) -> String {
        String(raw.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    /// Feed URLs advertised by a page: `<link rel="alternate" type="application/rss+xml">`
    /// (or atom). Relative hrefs are resolved against `base`. Comment feeds are skipped —
    /// nobody wants article suggestions from a comment thread.
    ///
    // ponytail: a regex over the head, not a DOM parse — the app's HTML parsing is
    // Readability's, in the web view, and this runs on a plain `URLSession` body.
    public static func discover(inHTML html: String, base: URL) -> [URL] {
        let head = String(html.prefix(200_000))
        let pattern = "<link\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        var found: [URL] = []
        var seen = Set<String>()
        for match in regex.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let range = Range(match.range, in: head) else { continue }
            let tag = String(head[range])
            let lower = tag.lowercased()
            guard lower.contains("rel=\"alternate\"") || lower.contains("rel='alternate'")
                    || lower.contains("rel=alternate") else { continue }
            guard lower.contains("rss+xml") || lower.contains("atom+xml") else { continue }
            guard !lower.contains("comment") else { continue }
            guard let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https",
                  seen.insert(url.absoluteString).inserted else { continue }
            found.append(url)
        }
        return found
    }

    /// The value of `name="…"` / `name='…'` in a tag, HTML-unescaped just enough for URLs.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')",
                                                   options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for group in 2...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range]).replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }
}

/// `XMLParser` delegate covering the RSS 2.0 and Atom elements we need. Both formats share
/// enough shape (a channel with a title and a language, then items with a title, a link and
/// a date) that one delegate handles them with a couple of per-format branches.
private final class FeedParser: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private(set) var channelTitle = ""
    private(set) var channelLanguage: String?
    private(set) var items: [FeedItem] = []

    /// Set once a recognizable feed root is seen; without it any well-formed XML would
    /// parse as an empty feed.
    private var isFeed = false
    private var inItem = false
    private var itemTitle = ""
    private var itemLink = ""
    private var itemDate: Date?
    private var text = ""
    /// Atom puts the item link in an attribute, so the text buffer is not the whole story.
    private var atomLink = ""
    private var path: [String] = []

    /// A reading app's suggestion pool, not an archive — a huge feed is truncated.
    private static let maxItems = 100

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
         "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    init(feedURL: URL) {
        self.feedURL = feedURL
        super.init()
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // A truncated or trailing-garbage feed still yields the items parsed so far.
        parser.parse()
        return isFeed
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = element.lowercased()
        path.append(name)
        text = ""
        switch name {
        case "rss", "rdf", "feed":
            isFeed = true
            if let lang = attributes["xml:lang"] ?? attributes["lang"] { channelLanguage = lang }
        case "item", "entry":
            inItem = true
            itemTitle = ""
            itemLink = ""
            atomLink = ""
            itemDate = nil
        case "link" where inItem:
            // Atom: <link rel="alternate" href="…">. Prefer alternate, else the first link.
            let rel = attributes["rel"] ?? "alternate"
            if let href = attributes["href"], rel == "alternate", atomLink.isEmpty { atomLink = href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let name = element.lowercased()
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title": if itemTitle.isEmpty { itemTitle = value }
            case "link", "guid", "id":
                // RSS puts the URL in the element text; Atom in the attribute read above.
                if itemLink.isEmpty, value.hasPrefix("http") { itemLink = value }
            case "pubdate", "published", "updated", "date":
                if itemDate == nil { itemDate = Self.date(from: value) }
            case "item", "entry":
                inItem = false
                let link = itemLink.isEmpty ? atomLink : itemLink
                guard !itemTitle.isEmpty, let url = URL(string: link, relativeTo: feedURL)?.absoluteURL,
                      url.scheme == "http" || url.scheme == "https",
                      items.count < Self.maxItems else { return }
                items.append(FeedItem(title: itemTitle, url: url.absoluteString,
                                      source: channelTitle, language: channelLanguage.map(Feed.baseLanguage),
                                      date: itemDate))
            default:
                break
            }
            return
        }
        switch name {
        case "title": if channelTitle.isEmpty { channelTitle = value }
        case "language": if channelLanguage == nil, !value.isEmpty { channelLanguage = value }
        default: break
        }
    }

    private static func date(from value: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Ranking feed items against what's been read. Pure and unit-tested; the host supplies the
/// candidates (`FeedFetcher`) and the read articles (`ArticleCache`).
///
// ponytail: TF-IDF cosine over title/body tokens rather than `NLEmbedding` — Apple ships no
// Danish sentence-embedding model (nor Swedish or Norwegian), so embeddings would rank the
// primary use case at random, and this keeps ReaderKit on Foundation alone. Revisit if a
// Danish model appears.
public enum Suggestions {
    /// How many rows the start page shows. A short list you might actually read, not a feed.
    public static let limit = 8

    /// Tokens for the bag of words: lowercase, split on anything non-alphanumeric, short
    /// tokens dropped, then truncated to a stem so Danish/English inflections ("valget",
    /// "valgets") collide. Crude, but it costs nothing and beats exact matching.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
            .map { String($0.prefix(6)) }
    }

    /// Strips tags (and their content for script/style) so an article's body contributes
    /// words rather than markup.
    static func plainText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Term frequencies, sublinearly scaled so a word repeated 40 times in a long article
    /// doesn't drown out everything else.
    private static func termFrequencies(_ tokens: [String]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }
        return counts.mapValues { 1 + log(Double($0)) }
    }

    private static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var dot = 0.0
        // Iterate the smaller map; the dot product only sees shared keys either way.
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        for (term, weight) in small where large[term] != nil { dot += weight * large[term]! }
        guard dot > 0 else { return 0 }
        let normA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return dot / (normA * normB)
    }

    /// The best `limit` candidates for someone who has read `read` (newest first).
    ///
    /// Items already in `readURLs`, in a filtered-out language, or duplicated across feeds
    /// are dropped; the rest are scored by cosine similarity between the item's title and a
    /// profile of the read articles (newer ones weigh more). With nothing read every score
    /// is 0 and the result is simply the newest candidates — the first-launch behavior.
    public static func rank(_ items: [FeedItem],
                            read: [Article],
                            readURLs: Set<String> = [],
                            languages: Set<String>? = nil,
                            limit: Int = Suggestions.limit) -> [FeedItem] {
        var candidates: [FeedItem] = []
        var seen = Set<String>()
        var seenTitles = Set<String>()
        for item in items {
            if let language = item.language, let languages, !languages.contains(language) { continue }
            guard let url = URL(string: item.url) else { continue }
            let key = URLCleaner.clean(url).absoluteString
            guard !readURLs.contains(key), seen.insert(key).inserted else { continue }
            // An aggregator carries the same wire story from several outlets under nearly
            // the same headline; without this the list is the same news three times.
            guard seenTitles.insert(tokens(item.title).joined(separator: " ")).inserted else { continue }
            candidates.append(item)
        }
        guard !candidates.isEmpty else { return [] }

        // One idf over read articles + candidate titles: a term common to everything (the
        // site name in every headline, "amp" from entities) ends up weighing ~nothing, which
        // is what a stopword list would have done by hand.
        let readTokens = read.map { tokens($0.title + " " + plainText($0.content)) }
        let candidateTokens = candidates.map { tokens($0.title) }
        let documents = readTokens + candidateTokens
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { documentFrequency[term, default: 0] += 1 }
        }
        let total = Double(documents.count)
        func idf(_ term: String) -> Double {
            log((total + 1) / (Double(documentFrequency[term] ?? 0) + 1)) + 1
        }

        // The reading profile: every read article's weighted tf-idf, newest counting most.
        var profile: [String: Double] = [:]
        for (index, document) in readTokens.enumerated() {
            let recency = 1 / sqrt(Double(index + 1))
            for (term, frequency) in termFrequencies(document) {
                profile[term, default: 0] += frequency * idf(term) * recency
            }
        }

        let scored = zip(candidates, candidateTokens).map { item, document -> (item: FeedItem, score: Double) in
            var weighted: [String: Double] = [:]
            for (term, frequency) in termFrequencies(document) { weighted[term] = frequency * idf(term) }
            return (item, cosine(weighted, profile))
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            // Same score (typically nothing read yet): newest first, undated last.
            return (left.item.date ?? .distantPast) > (right.item.date ?? .distantPast)
        }.prefix(limit).map(\.item)
    }
}
