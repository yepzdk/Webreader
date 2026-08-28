import XCTest
@testable import ReaderKit

// The suggestion core: the source list's codec, feed parsing/discovery, and the ranking.
// Fetching is URLSession orchestration, hand-verified per repo convention.
final class SuggestionsTests: XCTestCase {

    // MARK: - Source list

    func testUnstoredSettingsAreTheShippedDefault() {
        let settings = SuggestionSettings.fromJSON(nil)
        XCTAssertEqual(settings.sources, SuggestionSettings.defaults)
        XCTAssertNil(settings.languages)
    }

    func testRemovingTheDefaultSourceSticks() {
        // The whole point of a removable default: an emptied list must not re-seed.
        var settings = SuggestionSettings()
        settings.remove(url: SuggestionSettings.defaults[0].url)
        XCTAssertTrue(SuggestionSettings.fromJSON(settings.json).sources.isEmpty)
    }

    func testRoundTripsSourcesAndLanguages() {
        var settings = SuggestionSettings(sources: [])
        XCTAssertTrue(settings.add(FeedSource(url: "https://a.test/rss", title: "A", language: "da")))
        XCTAssertTrue(settings.add(FeedSource(url: "https://b.test/atom", title: "B", language: nil)))
        settings.languages = ["da"]
        let decoded = SuggestionSettings.fromJSON(settings.json)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.sources.map(\.title), ["A", "B"])
        XCTAssertEqual(decoded.availableLanguages, ["da"])
    }

    func testDuplicateAndOversizedAddsAreRejected() {
        var settings = SuggestionSettings(sources: [])
        XCTAssertTrue(settings.add(FeedSource(url: "https://a.test/rss", title: "A", language: nil)))
        XCTAssertFalse(settings.add(FeedSource(url: "https://a.test/rss", title: "A again", language: nil)))
        for i in 0..<SuggestionSettings.limit {
            settings.add(FeedSource(url: "https://x\(i).test/rss", title: "X", language: nil))
        }
        XCTAssertEqual(settings.sources.count, SuggestionSettings.limit)
    }

    func testGarbageJSONFallsBackToDefaults() {
        XCTAssertEqual(SuggestionSettings.fromJSON("{ not json").sources, SuggestionSettings.defaults)
    }

    func testAnEmptyLanguageSetRejectsEverythingThatDeclaresOne() {
        // Why the host must never STORE an empty set as a side effect (see the
        // readerRemoveSource handler): with the language section hidden below two
        // languages, the user would have no control left to undo it.
        let items = [FeedItem(title: "T", url: "https://a.test/1", source: "F", language: "en")]
        XCTAssertTrue(Suggestions.rank(items, read: [], languages: []).isEmpty)
        XCTAssertEqual(Suggestions.rank(items, read: [], languages: nil).count, 1)
    }

    // MARK: - Blocked outlets

    func testNormalizedHostIsOneDefinition() {
        XCTAssertEqual(Suggestions.normalizedHost("WWW.Extrabladet.DK"), "extrabladet.dk")
        XCTAssertEqual(Suggestions.normalizedHost("https://www.dr.dk/nyheder"), "dr.dk")
        XCTAssertEqual(Suggestions.normalizedHost("dr.dk."), "dr.dk")
        // What a row displays is exactly what a block stores.
        let row = FeedItem(title: "T", url: "https://www.extrabladet.dk/a/1", source: "F")
        var settings = SuggestionSettings(sources: [])
        settings.block(host: row.host)
        XCTAssertEqual(settings.blockedHosts, ["extrabladet.dk"])
    }

    func testBlockedOutletsAreDroppedFromSuggestions() {
        let items = [
            item("Ugly headline", "https://www.extrabladet.dk/a/1"),
            item("Something else", "https://dr.dk/b/2"),
        ]
        let ranked = Suggestions.rank(items, read: [], blockedHosts: ["extrabladet.dk"])
        XCTAssertEqual(ranked.map(\.url), ["https://dr.dk/b/2"])
    }

    func testBlockingMatchesTheWholeHostNotASuffix() {
        let items = [item("Innocent", "https://noget-extrabladet.dk/a")]
        XCTAssertEqual(Suggestions.rank(items, read: [], blockedHosts: ["extrabladet.dk"]).count, 1)
    }

    func testBlockedHostsRoundTripAndUnblock() {
        var settings = SuggestionSettings(sources: [])
        settings.block(host: "https://www.extrabladet.dk/forside")
        XCTAssertEqual(SuggestionSettings.fromJSON(settings.json).blockedHosts, ["extrabladet.dk"])
        settings.unblock(host: "EXTRABLADET.dk")
        XCTAssertTrue(SuggestionSettings.fromJSON(settings.json).blockedHosts.isEmpty)
    }

    // MARK: - More / less like this

    func testPreferringATopicLiftsSimilarHeadlines() {
        let items = [
            item("Ny rapport om vindmøller i Nordsøen", "https://a.test/vind", daysAgo: 5),
            item("Superligaen: dramatisk sejr til AGF", "https://a.test/agf", daysAgo: 0),
        ]
        // Nothing read: newest first puts the football story on top.
        XCTAssertEqual(Suggestions.rank(items, read: []).first?.url, "https://a.test/agf")
        var topics = TopicPreferences()
        topics.prefer("Vindmøller og havvind i Nordsøen")
        XCTAssertEqual(Suggestions.rank(items, read: [], topics: topics).first?.url, "https://a.test/vind")
    }

    func testAvoidingATopicPushesItDown() {
        let items = [
            item("Superligaen: dramatisk sejr til AGF", "https://a.test/agf", daysAgo: 0),
            item("Ny rapport om vindmøller", "https://a.test/vind", daysAgo: 5),
        ]
        var topics = TopicPreferences()
        topics.avoid("Superligaen fodbold AGF")
        XCTAssertEqual(Suggestions.rank(items, read: [], topics: topics).first?.url, "https://a.test/vind")
    }

    func testNoPreferencesLeavesRankingUntouched() {
        // Regression guard: the feature must be inert until the user uses it.
        let items = (0..<5).map { item("Overskrift nummer \($0) om noget", "https://a.test/\($0)", daysAgo: Double($0)) }
        let read = [article("Noget om vindmøller", "Vindmøller og havvind i Nordsøen")]
        XCTAssertEqual(Suggestions.rank(items, read: read).map(\.url),
                       Suggestions.rank(items, read: read, topics: TopicPreferences()).map(\.url))
    }

    func testInfluenceIsBoundedWhileTheStoredTotalIsNot() {
        // The total accumulates unclamped so a click can be undone exactly; the bound is
        // applied where it matters — when the weight influences ranking.
        var topics = TopicPreferences()
        for _ in 0..<20 { topics.prefer("vindmøller") }
        XCTAssertGreaterThan(topics.weights["vindmø"] ?? 0, TopicPreferences.clamp)
        XCTAssertEqual(topics.influence(of: "vindmø"), TopicPreferences.clamp)
        // Opposing clicks cancel out and the neutral term is forgotten, not stored as 0.
        var mixed = TopicPreferences()
        mixed.prefer("havvind")
        mixed.avoid("havvind")
        mixed.avoid("havvind")
        XCTAssertEqual(mixed.weights["havvin"], -0.5)
        for i in 0..<(TopicPreferences.limit + 50) { topics.prefer("emne\(i)ord") }
        XCTAssertLessThanOrEqual(topics.weights.count, TopicPreferences.limit)
    }

    func testRatingAnArticleTogglesAndReverses() {
        var topics = TopicPreferences()
        let title = "Vindmøller i Nordsøen udbygges"
        let url = "https://a.test/vind"
        XCTAssertNil(topics.rating(for: url))

        XCTAssertEqual(topics.setRating(.more, title: title, url: url), .more)
        XCTAssertEqual(topics.rating(for: url), .more)
        let liked = topics.weights

        // Same button again clears it, and the weights return exactly to neutral.
        XCTAssertNil(topics.setRating(.more, title: title, url: url))
        XCTAssertNil(topics.rating(for: url))
        XCTAssertTrue(topics.weights.isEmpty)

        // Switching sides must not leave both contributions applied.
        topics.setRating(.more, title: title, url: url)
        XCTAssertEqual(topics.weights, liked)
        topics.setRating(.less, title: title, url: url)
        XCTAssertEqual(topics.rating(for: url), .less)
        XCTAssertEqual(topics.weights["vindmø"], TopicPreferences.damp)
    }

    func testUndoingASaturatedTopicReturnsToNeutralNotToTheOpposite() {
        // Regression: clamping on write made the stored value stop being a sum of the
        // clicks, so undoing ten likes landed on a maximal DISLIKE of a liked topic.
        var topics = TopicPreferences()
        for i in 0..<10 { topics.setRating(.more, title: "Vindmøller", url: "https://a.test/\(i)") }
        XCTAssertGreaterThan(topics.influence(of: "vindmø"), 0)
        for i in 0..<10 { topics.setRating(.more, title: "Vindmøller", url: "https://a.test/\(i)") }
        XCTAssertTrue(topics.ratings.isEmpty)
        XCTAssertEqual(topics.influence(of: "vindmø"), 0)
        XCTAssertTrue(topics.weights.isEmpty)
    }

    func testATitleWithNoUsableTermsIsNotRecordedAsARating() {
        // Nothing can be learned from it, so leaving a button pressed would be a lie.
        var topics = TopicPreferences()
        XCTAssertNil(topics.setRating(.more, title: "!! ?? ..", url: "https://a.test/x"))
        XCTAssertNil(topics.rating(for: "https://a.test/x"))
        XCTAssertTrue(topics.weights.isEmpty)
    }

    func testRatingsSurviveARoundTripAndOldBareWeightMapsStillLoad() {
        var topics = TopicPreferences()
        topics.setRating(.less, title: "Superligaen fodbold", url: "https://a.test/agf")
        XCTAssertEqual(TopicPreferences.fromJSON(topics.json), topics)
        XCTAssertEqual(TopicPreferences.fromJSON(topics.json).rating(for: "https://a.test/agf"), .less)
        // The shape shipped before ratings existed.
        let legacy = TopicPreferences.fromJSON("{\"vind\":1.5}")
        XCTAssertEqual(legacy.weights["vind"], 1.5)
        XCTAssertTrue(legacy.ratings.isEmpty)
    }

    func testARatedArticleStillInfluencesRanking() {
        var topics = TopicPreferences()
        topics.setRating(.more, title: "Vindmøller og havvind i Nordsøen", url: "https://a.test/read")
        let items = [
            item("Ny rapport om vindmøller", "https://a.test/vind", daysAgo: 5),
            item("Superligaen: sejr til AGF", "https://a.test/agf", daysAgo: 0),
        ]
        XCTAssertEqual(Suggestions.rank(items, read: [], topics: topics).first?.url, "https://a.test/vind")
    }

    func testTopicPreferencesRoundTripTolerantly() {
        var topics = TopicPreferences()
        topics.prefer("Vindmøller i Nordsøen")
        XCTAssertEqual(TopicPreferences.fromJSON(topics.json), topics)
        XCTAssertTrue(TopicPreferences.fromJSON("{ not json").weights.isEmpty)
        XCTAssertTrue(TopicPreferences.fromJSON(nil).weights.isEmpty)
        // A stored total above the clamp is legitimate (it is a sum of clicks) and is kept,
        // but its effect on ranking is still bounded.
        let loud = TopicPreferences.fromJSON("{\"vind\":99}")
        XCTAssertEqual(loud.weights["vind"], 99)
        XCTAssertEqual(loud.influence(of: "vind"), TopicPreferences.clamp)
    }

    func testEmptyLanguageSelectionMustBeStoredAsNoFilter() {
        // The host converts an empty selection to nil; this pins WHY — an empty set is the
        // "reject everything that declares a language" case, which would silence the list
        // with no checkbox left to undo it.
        let items = [item("Dansk", "https://a.test/da", language: "da")]
        XCTAssertTrue(Suggestions.rank(items, read: [], languages: []).isEmpty)
        XCTAssertEqual(Suggestions.rank(items, read: [], languages: nil).count, 1)
    }

    // MARK: - Feed parsing

    private let rss = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0"><channel>
      <title>Nyeste artikler fra wallnot.dk</title>
      <link>https://wallnot.dk/rss</link>
      <language>da</language>
      <item>
        <title>Aktivister sigtes for banner hos Landbrug &amp; Fødevarer</title>
        <link>https://avisendanmark.dk/krimi/aktivister</link>
        <pubDate>Thu, 27 Aug 2026 13:55:10 +0200</pubDate>
      </item>
      <item>
        <title>Nyt OUH forsinkes igen</title>
        <link>https://www.kristeligt-dagblad.dk/danmark/nyt-ouh</link>
        <pubDate>Thu, 27 Aug 2026 13:53:44 +0200</pubDate>
      </item>
    </channel></rss>
    """

    func testParsesRSS() {
        let parsed = Feed.parse(Data(rss.utf8), from: URL(string: "https://wallnot.dk/rss")!)
        XCTAssertEqual(parsed?.title, "Nyeste artikler fra wallnot.dk")
        XCTAssertEqual(parsed?.language, "da")
        XCTAssertEqual(parsed?.items.count, 2)
        XCTAssertEqual(parsed?.items.first?.title, "Aktivister sigtes for banner hos Landbrug & Fødevarer")
        XCTAssertEqual(parsed?.items.first?.url, "https://avisendanmark.dk/krimi/aktivister")
        XCTAssertEqual(parsed?.items.first?.language, "da")
        XCTAssertNotNil(parsed?.items.first?.date)
        // The channel title travels with each item — it's what the row shows.
        XCTAssertEqual(parsed?.items.first?.source, "Nyeste artikler fra wallnot.dk")
    }

    func testParsesAtomIncludingTheLinkAttributeAndBaseLanguage() {
        let atom = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-GB">
          <title>Example Blog</title>
          <entry>
            <title>On caching</title>
            <link rel="alternate" href="/posts/caching"/>
            <updated>2026-08-20T10:00:00Z</updated>
          </entry>
        </feed>
        """
        let parsed = Feed.parse(Data(atom.utf8), from: URL(string: "https://blog.test/feed.xml")!)
        XCTAssertEqual(parsed?.title, "Example Blog")
        XCTAssertEqual(parsed?.language, "en")
        // Relative href resolved against the feed URL.
        XCTAssertEqual(parsed?.items.first?.url, "https://blog.test/posts/caching")
    }

    func testNonFeedDataIsNotAFeed() {
        XCTAssertNil(Feed.parse(Data("<html><body>Hello</body></html>".utf8),
                                from: URL(string: "https://x.test/")!))
        XCTAssertNil(Feed.parse(Data("not xml at all".utf8), from: URL(string: "https://x.test/")!))
    }

    // MARK: - Discovery

    func testDiscoversFeedLinksAndSkipsComments() {
        let html = """
        <html><head>
        <link rel="alternate" type="application/rss+xml" title="Comments" href="/comments/feed">
        <link rel="alternate" type="application/rss+xml" href="/feed">
        <link rel="alternate" type="application/atom+xml" href="https://other.test/atom">
        <link rel="stylesheet" href="/style.css">
        </head><body></body></html>
        """
        let found = Feed.discover(inHTML: html, base: URL(string: "https://site.test/blog")!)
        XCTAssertEqual(found.map(\.absoluteString),
                       ["https://site.test/feed", "https://other.test/atom"])
    }

    func testDiscoveryIgnoresPagesWithoutFeeds() {
        XCTAssertTrue(Feed.discover(inHTML: "<html><head><title>x</title></head></html>",
                                    base: URL(string: "https://site.test/")!).isEmpty)
    }

    // MARK: - Ranking

    private func item(_ title: String, _ url: String, language: String? = "da",
                      daysAgo: Double = 0) -> FeedItem {
        FeedItem(title: title, url: url, source: "Feed", language: language,
                 date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400))
    }

    private func article(_ title: String, _ body: String) -> Article {
        Article(title: title, byline: nil, siteName: nil, content: "<p>\(body)</p>")
    }

    func testRanksTopicalOverlapFirst() {
        let items = [
            item("Ny rapport om vindmøller i Nordsøen", "https://a.test/vind"),
            item("Superligaen: dramatisk sejr til AGF", "https://a.test/agf"),
            item("Klimaplan for havvind vedtaget", "https://a.test/havvind"),
        ]
        let read = [article("Havvind og vindmøller udbygges",
                            "Regeringens klimaplan for vindmøller i Nordsøen betyder mere havvind.")]
        let ranked = Suggestions.rank(items, read: read)
        XCTAssertEqual(ranked.count, 3)
        XCTAssertTrue(ranked.prefix(2).map(\.url).contains("https://a.test/vind"))
        XCTAssertTrue(ranked.prefix(2).map(\.url).contains("https://a.test/havvind"))
        XCTAssertEqual(ranked.last?.url, "https://a.test/agf")
    }

    func testNothingReadYieldsNewestFirst() {
        // First launch: no profile, so the shipped source is simply the latest news.
        let items = [
            item("Older", "https://a.test/old", daysAgo: 3),
            item("Newest", "https://a.test/new", daysAgo: 0),
            item("Middle", "https://a.test/mid", daysAgo: 1),
        ]
        XCTAssertEqual(Suggestions.rank(items, read: []).map(\.title), ["Newest", "Middle", "Older"])
    }

    func testAlreadyReadAndDuplicateItemsAreDropped() {
        let items = [
            item("Read already", "https://a.test/seen?utm_source=rss"),
            item("Fresh", "https://a.test/fresh"),
            item("Fresh again from another feed", "https://a.test/fresh"),
        ]
        // Recents store the cleaned URL, so the tracking-param variant must still match.
        let ranked = Suggestions.rank(items, read: [], readURLs: ["https://a.test/seen"])
        XCTAssertEqual(ranked.map(\.url), ["https://a.test/fresh"])
    }

    func testNearIdenticalHeadlinesFromDifferentOutletsCollapse() {
        // Aggregators carry the same wire story from several outlets; punctuation and a
        // stray connective make the titles differ by a character or two.
        let items = [
            item("Aktivister sigtes for banner hos Landbrug & Fødevarer", "https://a.test/1"),
            item("Aktivister sigtes for banner hos Landbrug og Fødevarer!", "https://b.test/2"),
            item("Noget helt andet sker i Randers", "https://c.test/3"),
        ]
        let ranked = Suggestions.rank(items, read: [])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(Set(ranked.map(\.url)), ["https://a.test/1", "https://c.test/3"])
    }

    func testLanguageFilterDropsOtherLanguagesButKeepsUndeclared() {
        let items = [
            item("Dansk artikel", "https://a.test/da", language: "da"),
            item("English piece", "https://a.test/en", language: "en"),
            item("Unknown language", "https://a.test/none", language: nil),
        ]
        let ranked = Suggestions.rank(items, read: [], languages: ["da"])
        XCTAssertEqual(Set(ranked.map(\.url)), ["https://a.test/da", "https://a.test/none"])
    }

    func testRowNamesTheArticlesOwnOutletNotTheAggregator() {
        // An aggregator's channel title says nothing about who wrote the piece.
        let item = FeedItem(title: "T", url: "https://www.kristeligt-dagblad.dk/danmark/x",
                            source: "Nyeste artikler fra wallnot.dk")
        XCTAssertEqual(item.host, "kristeligt-dagblad.dk")
    }

    func testRespectsTheLimit() {
        let items = (0..<20).map {
            item("Unik overskrift nummer \(["en","to","tre","fire","fem","seks","syv","otte","ni","ti","elleve","tolv","tretten","fjorten","femten","seksten","sytten","atten","nitten","tyve"][$0])",
                 "https://a.test/\($0)", daysAgo: Double($0))
        }
        XCTAssertEqual(Suggestions.rank(items, read: []).count, Suggestions.limit)
    }

    func testBodyMarkupDoesNotBecomeTokens() {
        // A body's tags and script must not contribute words to the profile.
        let read = [Article(title: "T", byline: nil, siteName: nil,
                            content: "<script>var vindmoeller = 1;</script><p>Kagerne smagte godt</p>")]
        let items = [item("Alt om vindmoeller", "https://a.test/v"),
                     item("Kagerne der smagte bedst", "https://a.test/k")]
        XCTAssertEqual(Suggestions.rank(items, read: read).first?.url, "https://a.test/k")
    }
}
