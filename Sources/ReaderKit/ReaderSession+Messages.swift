import Foundation

extension ReaderSession {
    /// What a generated page posted, as the value it posted.
    ///
    /// The three shapes are all the pages ever send. WebKit hands them over already bridged;
    /// a host that receives JSON text (WebKitGTK, Android) decodes into these. An enum rather
    /// than `Any` so the switch below cannot quietly accept the wrong shape from a host that
    /// decoded sloppily — and so the type is `Sendable`, which `Any` is not.
    public enum MessageBody: Equatable, Sendable {
        case text(String)
        case list([String])
        case object([String: Value])

        /// Only two kinds appear in anything the pages post: strings, and the font size.
        public enum Value: Equatable, Sendable {
            case text(String)
            case number(Int)

            public var text: String? {
                if case let .text(value) = self { return value }
                return nil
            }
        }

        public var text: String? {
            if case let .text(value) = self { return value }
            return nil
        }

        var fields: [String: Value]? {
            if case let .object(fields) = self { return fields }
            return nil
        }
    }

    /// One of the seventeen `reader*` messages.
    ///
    /// Every case is gated on which of our pages is actually showing: the handlers are
    /// session-wide, so a live site's JavaScript could otherwise post to them. `PageState`
    /// answers that question, and it is the only thing standing between a page we did not
    /// write and the reader's stored state.
    public func message(_ name: String, body: MessageBody) -> [ReaderCommand] {
        let ownPage = isShowingReader || pendingReaderRender || isShowingStartPage || isShowingSettings
        switch name {
        case "readerRetry":
            guard isShowingFallback else { return [] }
            guard let failedURL else { return showStartPage() }
            isShowingFallback = false
            return [.load(failedURL)]

        case "readerSettings":
            // Merged onto what is stored rather than decoded from defaults, so a page may
            // post only the fields it owns — the settings page posts one switch — and a
            // payload that is complete but stale cannot push its own idea of the rest.
            guard ownPage else { return [] }
            let current = ReaderStore.settings(store: store)
            ReaderStore.setSettings(ReaderSettings.decode(decoded(body), onto: current), store: store)
            onLocalStateChanged?()
            return []

        case "readerOpen":
            guard ownPage, let raw = body.text, let url = URL(string: raw) else { return [] }
            // A saved copy opens straight from disk: no load, no network. Only recents rows
            // take this shortcut — an incoming link is "read this now" and always loads live.
            let cleaned = URLCleaner.clean(url)
            if let cached = cache.article(for: cleaned) {
                return renderReader(cached, source: cleaned)
            }
            // A rejected URL must leave the reader state alone — the reader is still on
            // screen. Reject like the other explicit open paths.
            let opened = openIncoming(url)
            guard opened.accepted else { return [.reject] }
            // The row promises the reader, so enter it once this load finishes. Keyed to the
            // URL `openIncoming` actually loads, since it cleans first.
            enterReaderForURL = cleaned
            return opened.commands

        case "readerClear":
            guard ownPage else { return [] }
            // The tombstone, not an empty list: it is what makes the clear win over another
            // device's copy of the list on its next sync instead of being merged away.
            ReaderStore.clearHistory(store: store)
            cache.prune(keeping: [])
            onLocalStateChanged?()
            return []

        case "readerHide":
            // The reader page's floating affordance: learns the selection as a phrase, strips
            // it from the article live, and hides it in every article from now on. Rejects
            // when the selection isn't usable — no text, longer than a sentence, or already
            // stored.
            guard ownPage, let text = body.text else { return [] }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            guard phrases.add(text) else { return [.reject] }
            ReaderStore.setHiddenPhrases(phrases, store: store)
            // Unguarded on purpose: the page's Hide affordance has already cleared the
            // selection expecting the blocks to go, so a host that drops this leaves the text
            // on screen with nothing to say why.
            return [.evaluate("window.readerSetHidden(\(phrases.scriptLiteral))")]

        case "readerUnhide":
            guard ownPage, let phrase = body.text else { return [] }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            phrases.remove(phrase)
            ReaderStore.setHiddenPhrases(phrases, store: store)
            return []

        case "readerOpenSettings":
            guard isShowingStartPage else { return [] }
            return showSettingsPage()

        case "readerOpenSync":
            guard isShowingSettings else { return [] }
            return [.presentSyncSetup]

        case "readerHome":
            guard ownPage || isShowingFallback else { return [] }
            return showStartPage()

        case "readerAddSource":
            // Two pages post this. The offer on a not-a-page fallback already knows what the
            // address turned out to be, so accepting it costs no second lookup — and it is
            // matched against what was offered, so a page cannot talk this into adding an
            // address nobody looked at.
            if isShowingFallback, let offered = offeredFeed, body.text == offered.url {
                return addOfferedFeed(offered)
            }
            // The settings page has already disabled its button and waits for one of two
            // callbacks, so a host that answers neither leaves the form dead. Resolving a feed
            // is network work, which this method cannot do: the command hands it back to the
            // host, which awaits `resolveSource(_:)` and hands the answer to
            // `sourceResolved(_:)`.
            guard isShowingSettings, let raw = body.text,
                  let url = WebURL.clipboardURL(from: raw) else {
                return [Self.rejectSource()]
            }
            return [.resolveSource(url)]

        case "readerRemoveSource":
            guard isShowingSettings, let url = body.text else { return [] }
            var settings = ReaderStore.suggestions(store: store)
            settings.remove(url: url)
            // A language nobody publishes any more would linger in the filter forever. An
            // empty intersection must become "no filter", not "reject everything": the
            // language section disappears below two languages, so an empty set would silence
            // suggestions with no control left to undo it.
            settings.languages = settings.languages
                .map { $0.intersection(settings.availableLanguages) }
                .flatMap { $0.isEmpty ? nil : $0 }
            ReaderStore.setSuggestions(settings, store: store)
            return []

        case "readerSetLanguages":
            guard isShowingSettings, case let .list(codes) = body else { return [] }
            var settings = ReaderStore.suggestions(store: store)
            // Everything ticked is the same as no filter — and stays right when a source
            // introducing a new language is added later. Nothing ticked means the same: an
            // empty set makes `rank` reject every item that declares a language, which would
            // silence suggestions entirely (see `readerRemoveSource`).
            let chosen = Set(codes)
            settings.languages = chosen.isEmpty || chosen == Set(settings.availableLanguages)
                ? nil : chosen
            ReaderStore.setSuggestions(settings, store: store)
            return []

        case "readerBlockHost":
            guard isShowingStartPage, let host = body.text else { return [] }
            var settings = ReaderStore.suggestions(store: store)
            settings.block(host: host)
            ReaderStore.setSuggestions(settings, store: store)
            // Refill the slot the blocked row left behind. The fetcher's TTL cache means this
            // re-ranks what is already in memory rather than hitting the network again.
            return [.fetchSuggestions]

        case "readerUnblockHost":
            guard isShowingSettings, let host = body.text else { return [] }
            var settings = ReaderStore.suggestions(store: store)
            settings.unblock(host: host)
            ReaderStore.setSuggestions(settings, store: store)
            return []

        case "readerTopicFeedback":
            // Stored only — the list deliberately doesn't reshuffle under the cursor; the
            // page's toast is what tells the user it landed.
            guard isShowingStartPage, let fields = body.fields,
                  let title = fields["title"]?.text, let direction = fields["direction"]?.text,
                  !title.isEmpty else { return [] }
            var topics = ReaderStore.topics(store: store)
            switch direction {
            case "more": topics.prefer(title)
            case "less": topics.avoid(title)
            default: return []
            }
            ReaderStore.setTopics(topics, store: store)
            return []

        case "readerRate":
            // The reader's like/dislike. Keyed by the cleaned URL — the same key recents and
            // the cache use, so reopening an article shows the opinion you left on it.
            guard isShowingReader, let direction = body.text,
                  let rating = TopicPreferences.Rating(rawValue: direction),
                  let source = readerSourceURL else { return [] }
            // Terms come from the headline; without one there is nothing to learn.
            guard let title = readerArticleTitle, !title.isEmpty else { return [] }
            var topics = ReaderStore.topics(store: store)
            let now = topics.setRating(rating, title: title,
                                       url: URLCleaner.clean(source).absoluteString)
            ReaderStore.setTopics(topics, store: store)
            let value = now.map { "'\($0.rawValue)'" } ?? "null"
            return [.evaluate("window.readerSetRating && window.readerSetRating(\(value))")]

        case "readerOpenURL":
            // The start page's field, normalised like the clipboard route so bare
            // "example.com/x" works.
            guard isShowingStartPage, let raw = body.text else { return [] }
            guard let url = WebURL.clipboardURL(from: raw) else {
                return [.reject, .evaluate("window.readerURLRejected && window.readerURLRejected()")]
            }
            let opened = openIncoming(url)
            guard opened.accepted else {
                return [.reject, .evaluate("window.readerURLRejected && window.readerURLRejected()")]
            }
            return opened.commands

        default:
            return []
        }
    }

    /// `ReaderSettings.decode` takes what a host's bridge produced — on WebKit a bridged
    /// dictionary, elsewhere a decoded JSON value. The enum is flattened back to that here
    /// so the codec keeps one entry point and one set of tolerances.
    private func decoded(_ body: MessageBody) -> Any {
        switch body {
        case let .text(value): return value
        case let .list(values): return values
        case let .object(fields):
            return fields.mapValues { value -> Any in
                switch value {
                case let .text(text): return text
                case let .number(number): return number
                }
            }
        }
    }

    // MARK: - The parts that have to wait for the network

    /// Everything the ranking reads, taken off the session in one go.
    ///
    /// A snapshot rather than the session itself, because the ranking is the one thing that
    /// happens while the host carries on driving: the fetch resumes on another thread, and a
    /// method that read `store` or the cache from there would be reading them mid-change.
    public struct SuggestionRequest: Sendable {
        let sources: [FeedSource]
        let languages: Set<String>?
        let blockedHosts: Set<String>
        let topics: TopicPreferences
        let read: [Article]
        let readURLs: Set<String>
    }

    /// Snapshots what the ranking needs, on the session's own thread like everything else.
    ///
    /// The profile is the recent articles' own text, straight from the cache. A row whose
    /// body has fallen out of the cache still contributes its title — a weaker signal than
    /// the full text, but far better than dropping the article from the profile.
    public func suggestionRequest() -> SuggestionRequest {
        let settings = ReaderStore.suggestions(store: store)
        let history = ReaderStore.history(store: store)
        let read = history.entries.map { entry in
            URL(string: entry.url).flatMap { cache.article(for: $0) }
                ?? Article(title: entry.title, byline: nil, siteName: nil, content: "")
        }
        return SuggestionRequest(sources: settings.sources,
                                 languages: settings.languages,
                                 blockedHosts: settings.blockedHosts,
                                 topics: ReaderStore.topics(store: store),
                                 read: read,
                                 readURLs: Set(history.entries.map(\.url)))
    }

    /// Fetches the sources and ranks them against what has been read.
    ///
    /// One of the two methods a host may await off the thread it drives the session from,
    /// and for the same reason: nothing session-owned is reachable from here. `FeedFetcher`
    /// is an actor, and everything else arrived in `request`.
    public func suggestions(for request: SuggestionRequest) async -> [FeedItem] {
        guard !request.sources.isEmpty else { return [] }
        let items = await feeds.items(for: request.sources)
        return Suggestions.rank(items, read: request.read,
                                readURLs: request.readURLs,
                                languages: request.languages,
                                blockedHosts: request.blockedHosts,
                                topics: request.topics)
    }

    /// Hands the ranked list to whichever page shows suggestions. Both surfaces implement
    /// `readerSetSuggestions`; each renders the shape that fits it. An empty list is worth
    /// sending: no sources is precisely when the page's "add a source" empty state should
    /// show, rather than the section staying hidden.
    ///
    /// Gated because the ranking can land after the page it was ranked for went away, and
    /// these rows are ranked against everything this device has read. Without the gate they
    /// would be evaluated into whatever document is on screen by then, including a site's.
    public func showSuggestions(_ items: [FeedItem]) -> [ReaderCommand] {
        guard isShowingStartPage || isShowingReader else { return [] }
        let rows: [[String: String]] = items.map { item in
            var row = ["title": item.title, "url": item.url, "source": item.host]
            if let image = item.image { row["image"] = image }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else {
            return []
        }
        return [.evaluate("window.readerSetSuggestions && window.readerSetSuggestions(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")]
    }

    /// Looks a feed address up: the half of `readerAddSource` that has to wait for a server.
    /// Awaitable off the session's thread on the same terms as `suggestions(for:)`.
    public func resolveSource(_ url: URL) async -> FeedSource? {
        try? await feeds.resolve(url)
    }

    /// Stores what the lookup found and tells the page that asked which of the two answers it
    /// got — and there are two pages that ask.
    ///
    /// From the settings page's form it is added straight away, which is what that form is
    /// for. From an address that turned out to be a file, nothing is added yet: the page only
    /// offers, because opening a link is not the same as asking to subscribe to it, and
    /// nobody typed that address wanting a source list changed under them.
    ///
    /// Nothing to say to a page that has gone: the form this would re-enable went with it, and
    /// the message would land in whatever replaced it.
    public func sourceResolved(_ source: FeedSource?) -> [ReaderCommand] {
        if isShowingFallback {
            guard let source else { return [] }
            offeredFeed = source
            let row: [String: Any] = ["title": source.title, "url": source.url]
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: []) else {
                return []
            }
            return [.evaluate("window.readerOfferFeed && window.readerOfferFeed(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")]
        }
        guard isShowingSettings else { return [] }
        guard let source else { return [Self.rejectSource()] }
        var settings = ReaderStore.suggestions(store: store)
        let languagesBefore = settings.availableLanguages
        guard settings.add(source) else {
            // `add` refuses a duplicate and a full list; saying the wrong one is worse than
            // saying nothing, so tell them apart.
            return [Self.rejectSource(message: settings.sources.count >= SuggestionSettings.limit
                ? "That is as many sources as this list holds (\(SuggestionSettings.limit))."
                : "That source is already in the list.")]
        }
        ReaderStore.setSuggestions(settings, store: store)
        // The language section only exists once two languages are in play, and it is built in
        // Swift — crossing that line is the one case the page cannot update in place.
        if languagesBefore.count < 2, settings.availableLanguages.count >= 2 {
            return showSettingsPage()
        }
        let row: [String: Any] = ["title": source.title, "url": source.url,
                                  "language": source.language as Any]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: []) else { return [] }
        return [.evaluate("window.readerSourceAdded && window.readerSourceAdded(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")]
    }

    /// Adds the feed the not-a-page fallback offered, and goes to the start page — which is
    /// where its articles will turn up, and a better place to be left than a page that says
    /// there is nothing to read.
    ///
    /// A duplicate lands there too, because "this feed is one of my sources" is then already
    /// true and the page has nothing to add. A full list is the one case this says nothing
    /// about; the list it could not join is on the settings page, which is where it lives.
    private func addOfferedFeed(_ source: FeedSource) -> [ReaderCommand] {
        offeredFeed = nil
        var settings = ReaderStore.suggestions(store: store)
        guard settings.add(source) else { return showStartPage() }
        ReaderStore.setSuggestions(settings, store: store)
        onLocalStateChanged?()
        return showStartPage()
    }

    /// Re-enables the settings page's add form with an inline message.
    static func rejectSource(message: String = "No feed found at that address.") -> ReaderCommand {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return .evaluate("window.readerSourceRejected && window.readerSourceRejected('\(escaped)')")
    }
}
