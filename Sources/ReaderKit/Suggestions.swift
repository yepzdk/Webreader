import Foundation
// `XMLParser` ships in Foundation proper on Apple platforms but in a separate module under
// swift-corelibs-foundation, so the Linux host (issue #16) needs this to see `Feed.parse`.
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Where suggested articles come from: a feed the user has added (or the shipped default).
/// `title` is the feed's own channel title, resolved once when the source is added, so the
/// settings list can name a source without re-fetching it.
public struct FeedSource: Equatable, Codable, Sendable {
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
public struct SuggestionSettings: Equatable, Sendable {
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
    /// Outlets never to suggest, as normalized hosts ("extrabladet.dk"). Per host rather than
    /// per source: an aggregator carries many outlets, and it's the outlet you don't want.
    public var blockedHosts: Set<String>

    public init(sources: [FeedSource] = SuggestionSettings.defaults, languages: Set<String>? = nil,
                blockedHosts: Set<String> = []) {
        self.sources = sources
        self.languages = languages
        self.blockedHosts = blockedHosts
    }

    /// Blocks an outlet. Normalized on the way in so a host from a row, a URL or a typed
    /// string all land on the same key.
    public mutating func block(host: String) {
        let host = Suggestions.normalizedHost(host)
        guard !host.isEmpty else { return }
        blockedHosts.insert(host)
    }

    public mutating func unblock(host: String) {
        blockedHosts.remove(Suggestions.normalizedHost(host))
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
        if !blockedHosts.isEmpty { dict["blocked"] = blockedHosts.sorted() }
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
        if let blocked = dict["blocked"] as? [String] {
            settings.blockedHosts = Set(blocked.map(Suggestions.normalizedHost).filter { !$0.isEmpty })
        }
        return settings
    }
}

/// One candidate article from a feed.
public struct FeedItem: Equatable, Sendable {
    public let title: String
    public let url: String
    /// The feed's channel title. Kept for provenance, but the start page's second line is
    /// the article's own host: an aggregator's channel title ("Nyeste artikler fra
    /// wallnot.dk") says nothing about who wrote the piece, and the host does.
    public let source: String
    public let language: String?
    public let date: Date?
    /// The article's image as the feed itself declared it, absolute and http(s), or nil when
    /// the feed named none (#25). Feeds are the only thing we have to go on here: a suggested
    /// article has not been visited, so there is no document to read an `og:image` from, and
    /// fetching every candidate's page just for a thumbnail would mean a request per row to
    /// publishers the reader has not opened.
    public let image: String?

    /// The outlet the row names — and the exact string a block is stored under, so what the
    /// user sees is what they block.
    public var host: String { Suggestions.normalizedHost(URL(string: url)?.host ?? source) }

    public init(title: String, url: String, source: String, language: String? = nil,
                date: Date? = nil, image: String? = nil) {
        self.title = title
        self.url = url
        self.source = source
        self.language = language
        self.date = date
        self.image = image
    }
}

/// What the reader has explicitly asked for more or less of — the ranking's one visible
/// dial, fed by the More/Less controls on a suggested row.
///
/// Keyed by the same stemmed tokens the ranker uses, so a preference expressed on one
/// headline transfers to related ones instead of pinning a single article.
public struct TopicPreferences: Equatable, Sendable {
    /// One click's worth of nudge. Asking for more is a stronger signal than asking for
    /// less: "not this one right now" is a weaker statement than "yes, this".
    public static let boost = 1.5
    public static let damp = -1.0
    /// How far repeated clicks can push one term, and how many terms are remembered.
    public static let clamp = 3.0
    public static let limit = 200
    /// A sanity bound on what a stored total may be, for hand-edited or corrupt blobs only.
    /// Far above anything clicking produces, so it never interferes with a legitimate undo.
    static let maxStoredWeight = 1_000.0

    /// Which way an article was rated. Also what the reader page's buttons render.
    public enum Rating: String, Sendable { case more, less }

    public private(set) var weights: [String: Double]
    /// The articles carrying an opinion, by cleaned URL — so the reader can show its buttons
    /// in the right state, and so a rating can be undone by replaying exactly its own terms.
    /// The weights alone don't say which article contributed what, so without this a click
    /// could not be taken back. (The replay itself is exact because totals accumulate
    /// unclamped — see `apply` — though evicting a term at `limit` can still lose one.)
    public private(set) var ratings: [String: Rating]

    /// How many rated articles are remembered. The weights outlive this — forgetting the
    /// oldest rating drops the ability to *toggle* that article, not its influence.
    public static let ratingsLimit = 300

    public init(weights: [String: Double] = [:], ratings: [String: Rating] = [:]) {
        self.weights = weights
        self.ratings = ratings
    }

    public mutating func prefer(_ title: String) { apply(title, delta: Self.boost) }
    public mutating func avoid(_ title: String) { apply(title, delta: Self.damp) }

    /// How `url` is currently rated, if at all.
    public func rating(for url: String) -> Rating? { ratings[url] }

    /// Applies `rating` to an article, or clears it when the same rating is set twice — the
    /// toggle behind the reader's buttons. Returns the rating now in force (nil = cleared),
    /// so the host can tell the page what to draw without re-reading the store.
    @discardableResult
    public mutating func setRating(_ rating: Rating, title: String, url: String) -> Rating? {
        let current = ratings[url]
        // Whatever was there is undone first, so switching sides never leaves both applied.
        if let current {
            apply(title, delta: current == .more ? -Self.boost : -Self.damp)
            ratings[url] = nil
        }
        guard current != rating else { return nil }
        // A headline with no usable terms (punctuation, a bare number) teaches nothing, so
        // there is no opinion to record — a button left pressed over an empty preference
        // would be a lie.
        guard apply(title, delta: rating == .more ? Self.boost : Self.damp) else { return nil }
        ratings[url] = rating
        if ratings.count > Self.ratingsLimit { forgetOldestRatings() }
        return rating
    }

    /// Dictionaries are unordered, so "oldest" isn't knowable — drop an arbitrary excess
    /// instead. The cap is a safety valve on storage, not a recency policy.
    // ponytail: an ordered list of rated URLs would make this exact; not worth the bytes
    // until someone rates 300 articles and complains a toggle went stale.
    private mutating func forgetOldestRatings() {
        for url in ratings.keys.prefix(ratings.count - Self.ratingsLimit) { ratings[url] = nil }
    }

    /// Adds `delta` to every term of `title`. Returns false when the title yields no terms,
    /// so a rating that would change nothing isn't recorded as one.
    ///
    /// The stored total is deliberately NOT clamped: clamping on the way in makes the value
    /// stop being a faithful sum of the clicks, and undoing a click then can't reverse it —
    /// ten likes saturating at +3 used to undo to −3, a maximal dislike of a topic the user
    /// had repeatedly liked. `influence(of:)` clamps at the point of use instead.
    @discardableResult
    private mutating func apply(_ title: String, delta: Double) -> Bool {
        let terms = Set(Suggestions.tokens(title))
        guard !terms.isEmpty else { return false }
        for term in terms {
            weights[term] = (weights[term] ?? 0) + delta
        }
        // A term nudged back to neutral is not a preference — drop it rather than storing 0.
        // The rounding guard keeps repeated ±1.5/±1.0 arithmetic from leaving a 1e-16 ghost.
        weights = weights.filter { abs($0.value) > 1e-9 }
        guard weights.count > Self.limit else { return true }
        // Over the cap, the least-committed opinions go first.
        let keep = weights.sorted { abs($0.value) > abs($1.value) }.prefix(Self.limit)
        weights = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        return true
    }

    /// A term's effect on ranking: the accumulated total, bounded so no single topic can run
    /// away with the list however many times it has been liked.
    public func influence(of term: String) -> Double {
        min(max(weights[term] ?? 0, -Self.clamp), Self.clamp)
    }

    public var json: String {
        let dict: [String: Any] = ["weights": weights, "ratings": ratings.mapValues(\.rawValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tolerant like the rest of the stored state: nil/garbage means no preferences, and a
    /// malformed entry is skipped rather than poisoning the map.
    public static func fromJSON(_ string: String?) -> TopicPreferences {
        guard let string, let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return TopicPreferences() }
        // The first shipped shape was a bare term->weight map; keep reading it so an early
        // tester's preferences survive the upgrade.
        let raw = (object["weights"] as? [String: Any]) ?? object
        var weights: [String: Double] = [:]
        for (term, value) in raw {
            guard let number = value as? Double ?? (value as? Int).map(Double.init),
                  abs(number) > 1e-9, number.isFinite, !term.isEmpty else { continue }
            // Stored totals are unclamped on purpose (see `apply`) — clamping here would
            // truncate an accumulated total and break the undo. Only absurd hand-edited
            // values are reined in, generously, so a rating can still be reversed.
            weights[term] = min(max(number, -maxStoredWeight), maxStoredWeight)
        }
        if weights.count > limit {
            let keep = weights.sorted { abs($0.value) > abs($1.value) }.prefix(limit)
            weights = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        var ratings: [String: Rating] = [:]
        for (url, value) in (object["ratings"] as? [String: String]) ?? [:] {
            guard !url.isEmpty, let rating = Rating(rawValue: value) else { continue }
            ratings[url] = rating
        }
        if ratings.count > ratingsLimit {
            ratings = Dictionary(uniqueKeysWithValues: ratings.prefix(ratingsLimit).map { ($0.key, $0.value) })
        }
        return TopicPreferences(weights: weights, ratings: ratings)
    }
}

/// Parsing feeds and finding them in a page. Pure — the fetching lives in `FeedFetcher`.
public enum Feed {
    public struct Parsed: Equatable, Sendable {
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

    /// The first `<img>` source in a feed item's summary HTML — Information, The Verge and
    /// The New Stack put the lead image there and carry no structured image tag at all.
    ///
    /// Images declaring a width or height of 1 are skipped: that is the shape of a tracking
    /// beacon (FeedBurner's, among others), not of an article's picture.
    static func firstImage(inHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>",
                                                   options: [.caseInsensitive])
        else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            if numeric("width", in: tag) == 1 || numeric("height", in: tag) == 1 { continue }
            if let src = attribute("src", in: tag), !src.isEmpty { return src }
        }
        return nil
    }

    /// Picks the image best suited to a 64x40 thumbnail from a feed item's candidates: the
    /// smallest the feed declares that is still wide enough for a HiDPI row, else the widest
    /// on offer. The Guardian ships three widths per item (140, 460, 700) and Ars Technica a
    /// 1152px hero, so "whichever came first" is either visibly soft or several hundred KB
    /// per row.
    ///
    /// A candidate without a declared width loses only to one that qualifies, so a feed that
    /// declares no sizes still gets a thumbnail.
    static func bestImage(_ candidates: [(url: String, width: Int?)]) -> String? {
        let sized = candidates.compactMap { candidate in candidate.width.map { (candidate.url, $0) } }
        if let fit = sized.filter({ $0.1 >= thumbnailMinimumWidth }).min(by: { $0.1 < $1.1 }) {
            return fit.0
        }
        if let widest = sized.max(by: { $0.1 < $1.1 }) { return widest.0 }
        return candidates.first?.url
    }

    /// A 64px row at 2x. Anything narrower is visibly soft.
    static let thumbnailMinimumWidth = 128

    /// The value of an integer attribute, e.g. `width="1"`.
    private static func numeric(_ name: String, in tag: String) -> Int? {
        attribute(name, in: tag).flatMap { Int($0) }
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
        // Bounded by `</head>`, not by a character count. A `<link rel="alternate">` is a head
        // element, so that is the honest end of the search — and a fixed cap loses it on any
        // page that inlines its stylesheets first: theguardian.com puts ~580 KB of them ahead
        // of the tag, so a 200 KB cap made the paper look like it had no feed at all. Scanning
        // a whole document with no `</head>` costs a regex pass over bytes already in memory,
        // once, on a deliberate user action.
        let head = html.range(of: "</head>", options: [.caseInsensitive])
            .map { String(html[html.startIndex..<$0.lowerBound]) } ?? html
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
                return unescapeAmpersands(String(tag[range]))
            }
        }
        return nil
    }

    /// Every spelling of an escaped ampersand a feed might use, decoded — the only entity that
    /// actually turns up inside a URL, and it separates query parameters, so leaving it
    /// encoded hands the server a parameter called `#038;strip`. The Verge's feed escapes it
    /// numerically inside already-escaped summary HTML, so `&amp;` alone is not enough.
    private static func unescapeAmpersands(_ value: String) -> String {
        guard value.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(?:amp;|#0*38;|#[xX]0*26;)",
                                                   options: [.caseInsensitive])
        else { return value }
        return regex.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "&")
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
    /// Every image the current item declared through a structured tag, with the width the
    /// feed claimed for it. Collected rather than first-wins, because feeds ship several
    /// sizes and only one of them suits a thumbnail (`Feed.bestImage`).
    private var itemImages: [(url: String, width: Int?)] = []
    /// The lead image found in the item's summary HTML, used only when no structured tag
    /// offered one.
    private var itemBodyImage: String?

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
        // A truncated or trailing-garbage feed still yields the items parsed so far, so the
        // Bool is discarded on purpose — `isFeed` is the answer. Discarded explicitly because
        // corelibs-Foundation does not mark `parse()` `@discardableResult` the way Darwin
        // does, and the Android cross-build is the only place that warns.
        _ = parser.parse()
        return isFeed
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = element.lowercased()
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
            itemImages = []
            itemBodyImage = nil
        case "link" where inItem:
            // Atom: <link rel="alternate" href="…">. Prefer alternate, else the first link.
            let rel = attributes["rel"] ?? "alternate"
            if let href = attributes["href"], rel == "alternate", atomLink.isEmpty { atomLink = href }
        // Media RSS. The Guardian declares neither `type` nor `medium`, so these are taken as
        // images unless they say otherwise; a URL that turns out not to be one removes itself
        // from the page (`onerror`) rather than leaving a broken glyph.
        case "media:thumbnail", "media:content":
            guard inItem, let url = attributes["url"] else { break }
            let kind = (attributes["medium"] ?? attributes["type"] ?? "image").lowercased()
            guard kind == "image" || kind.hasPrefix("image/") else { break }
            itemImages.append((url, attributes["width"].flatMap { Int($0) }))
        // An enclosure carries podcasts and video too, so here the type has to say image.
        case "enclosure":
            guard inItem, let url = attributes["url"],
                  (attributes["type"] ?? "").lowercased().hasPrefix("image/") else { break }
            itemImages.append((url, attributes["width"].flatMap { Int($0) }))
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
            case "description", "summary", "content", "content:encoded":
                // Escaped or CDATA-wrapped HTML; either way the buffer holds real markup by
                // the time it gets here.
                if itemBodyImage == nil { itemBodyImage = Feed.firstImage(inHTML: value) }
            case "item", "entry":
                inItem = false
                let link = itemLink.isEmpty ? atomLink : itemLink
                guard !itemTitle.isEmpty, let url = URL(string: link, relativeTo: feedURL)?.absoluteURL,
                      url.scheme == "http" || url.scheme == "https",
                      items.count < Self.maxItems else { return }
                items.append(FeedItem(title: itemTitle, url: url.absoluteString,
                                      source: channelTitle, language: channelLanguage.map(Feed.baseLanguage),
                                      date: itemDate, image: resolvedImage()))
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

    /// The current item's thumbnail: the best structured candidate, else the summary's lead
    /// image. Absolutised against the feed (feeds do carry relative image paths) and limited
    /// to http(s) — the value is somebody else's markup and nothing else belongs in an
    /// `<img src>`.
    private func resolvedImage() -> String? {
        guard let raw = Feed.bestImage(itemImages) ?? itemBodyImage,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                            relativeTo: feedURL)?.absoluteURL,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url.absoluteString
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

    /// The canonical form of an outlet's host: lowercased, no leading "www.", no trailing
    /// dot. One definition, used by the row that displays a host and by the blocklist that
    /// stores one — otherwise a stored block could silently fail to match what's shown.
    public static func normalizedHost(_ raw: String) -> String {
        var host = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Tolerate a whole URL being passed in ("https://www.dr.dk/nyheder").
        if host.contains("://"), let parsed = URL(string: host)?.host { host = parsed }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

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
    /// Items already read, in a filtered-out language, or duplicated across feeds
    /// are dropped; the rest are scored by cosine similarity between the item's title and a
    /// profile of the read articles (newer ones weigh more). With nothing read every score
    /// is 0 and the result is simply the newest candidates — the first-launch behavior.
    public static func rank(_ items: [FeedItem],
                            read: [Article],
                            readURLs: Set<String> = [],
                            languages: Set<String>? = nil,
                            blockedHosts: Set<String> = [],
                            topics: TopicPreferences = TopicPreferences(),
                            limit: Int = Suggestions.limit) -> [FeedItem] {
        // Both sides of "have I read this?" are keyed here rather than by the caller: the
        // comparison was between a feed's spelling of an address and the one the site
        // redirected to, and a caller that has to remember which form to pass will
        // eventually pass the other one.
        let readKeys = Set(readURLs.compactMap { URL(string: $0).map(URLCleaner.identity) })
        var candidates: [FeedItem] = []
        var seen = Set<String>()
        var seenTitles = Set<String>()
        for item in items {
            if let language = item.language, let languages, !languages.contains(language) { continue }
            // Exact host, never a suffix: blocking "extrabladet.dk" must not also silence
            // some unrelated "noget-extrabladet.dk".
            if blockedHosts.contains(item.host) { continue }
            guard let url = URL(string: item.url) else { continue }
            // The same-article key, not the navigable URL: a feed's `dr.dk/x` and the
            // `www.dr.dk/x` the site redirected to are one article, and comparing the two
            // strings kept offering people what they had just finished reading.
            let key = URLCleaner.identity(url)
            guard !readKeys.contains(key), seen.insert(key).inserted else { continue }
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
            // Cosine is 0...1; the explicit nudge is scaled to be of comparable size — enough
            // to move a headline several places, never enough to pin one topic to the top
            // forever regardless of what's actually been read.
            var nudge = 0.0
            if !topics.weights.isEmpty, !document.isEmpty {
                for term in Set(document) { nudge += topics.influence(of: term) * idf(term) }
                nudge /= Double(Set(document).count) * TopicPreferences.clamp
            }
            return (item, cosine(weighted, profile) + nudge)
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            // Same score (typically nothing read yet): newest first, undated last.
            return (left.item.date ?? .distantPast) > (right.item.date ?? .distantPast)
        }.prefix(limit).map(\.item)
    }
}
