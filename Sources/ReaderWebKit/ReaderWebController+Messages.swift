import Foundation
import WebKit
import ReaderKit

extension ReaderWebController {
    // MARK: - Messages from our pages

    // Each message is honored only while its page is actually showing — the handlers are
    // controller-wide, so a live site's JS could otherwise post to them.
    //
    // WebKit delivers these on the main thread, but the protocol requirement isn't annotated,
    // so the isolation has to be spelled out for the main-actor UI work the cases do.
    @MainActor
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        let ownPage = isShowingReader || pendingReaderRender || isShowingStartPage || isShowingSettings
        switch message.name {
        case "readerRetry":
            guard isShowingFallback else { return }
            if let failedURL {
                isShowingFallback = false
                webView.load(URLRequest(url: failedURL))
            } else {
                showStartPage()
            }
        case "readerSettings":
            // Merged onto what is stored rather than decoded from defaults, so a page may
            // post only the fields it owns — the settings page posts one switch — and a
            // payload that is complete but stale cannot push its own idea of the rest.
            guard ownPage else { return }
            let current = ReaderStore.settings(store: store)
            ReaderStore.setSettings(ReaderSettings.decode(message.body, onto: current),
                                    store: store)
            sync?.localStateChanged()
        case "readerOpen":
            guard ownPage, let raw = message.body as? String, let url = URL(string: raw) else { return }
            // A saved copy opens straight from disk: no load, no network. Only recents rows
            // take this shortcut — an incoming link is "read this now" and always loads live.
            let cleaned = URLCleaner.clean(url)
            if let cached = cache.article(for: cleaned) {
                renderReader(cached, source: cleaned)
                return
            }
            // A rejected URL must leave the reader state alone — the reader is still on
            // screen. Reject like the other explicit open paths.
            guard openIncoming(url) else {
                services.reject()
                return
            }
            // The row promises the reader, so enter it once this load finishes. Keyed to
            // the URL `openIncoming` actually loads (it cleans first).
            enterReaderForURL = cleaned
        case "readerClear":
            guard ownPage else { return }
            // The tombstone, not an empty list: it's what makes the clear win over another
            // device's copy of the list on its next sync instead of being merged away.
            ReaderStore.clearHistory(store: store)
            cache.prune(keeping: [])
            sync?.localStateChanged()
        case "readerHide":
            // The reader page's floating affordance, where the Edit-menu item used to be:
            // learns the selection as a phrase, strips it from the article live, and hides
            // it in every article from now on. Rejects when the selection isn't usable — no
            // text, longer than a sentence, or already stored.
            guard ownPage, let text = message.body as? String else { return }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            guard phrases.add(text) else {
                services.reject()
                return
            }
            ReaderStore.setHiddenPhrases(phrases, store: store)
            webView.evaluateJavaScript("window.readerSetHidden(\(phrases.scriptLiteral))")
        case "readerUnhide":
            guard ownPage, let phrase = message.body as? String else { return }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            phrases.remove(phrase)
            ReaderStore.setHiddenPhrases(phrases, store: store)
        case "readerOpenSettings":
            guard isShowingStartPage else { return }
            showSettingsPage()
        case "readerOpenSync":
            guard isShowingSettings else { return }
            services.presentSyncSetup()
        case "readerHome":
            guard ownPage || isShowingFallback else { return }
            showStartPage()
        case "readerAddSource":
            // The page has already disabled its button; it waits for one of the two callbacks.
            guard isShowingSettings, let raw = message.body as? String,
                  let url = WebURL.clipboardURL(from: raw) else {
                rejectSource()
                return
            }
            Task { [weak self] in
                guard let self else { return }
                guard let source = try? await self.feeds.resolve(url) else {
                    await MainActor.run { self.rejectSource() }
                    return
                }
                await MainActor.run { self.addSource(source) }
            }
        case "readerRemoveSource":
            guard isShowingSettings, let url = message.body as? String else { return }
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
        case "readerSetLanguages":
            guard isShowingSettings, let codes = message.body as? [String] else { return }
            var settings = ReaderStore.suggestions(store: store)
            // Everything ticked is the same as no filter — and stays right when a source
            // introducing a new language is added later. Nothing ticked means the same:
            // an empty set makes `rank` reject every item that declares a language, which
            // would silence suggestions entirely (see the `readerRemoveSource` case).
            let chosen = Set(codes)
            settings.languages = chosen.isEmpty || chosen == Set(settings.availableLanguages)
                ? nil : chosen
            ReaderStore.setSuggestions(settings, store: store)
        case "readerBlockHost":
            guard isShowingStartPage, let host = message.body as? String else { return }
            var settings = ReaderStore.suggestions(store: store)
            settings.block(host: host)
            ReaderStore.setSuggestions(settings, store: store)
            // Refill the slot the blocked row left behind. The fetcher's TTL cache means this
            // re-ranks what's already in memory rather than hitting the network again.
            loadSuggestions()
        case "readerUnblockHost":
            guard isShowingSettings, let host = message.body as? String else { return }
            var settings = ReaderStore.suggestions(store: store)
            settings.unblock(host: host)
            ReaderStore.setSuggestions(settings, store: store)
        case "readerTopicFeedback":
            // Stored only — the list deliberately doesn't reshuffle under the cursor; the
            // page's toast is what tells the user it landed.
            guard isShowingStartPage, let body = message.body as? [String: Any],
                  let title = body["title"] as? String, let direction = body["direction"] as? String,
                  !title.isEmpty else { return }
            var topics = ReaderStore.topics(store: store)
            switch direction {
            case "more": topics.prefer(title)
            case "less": topics.avoid(title)
            default: return
            }
            ReaderStore.setTopics(topics, store: store)
        case "readerRate":
            // The reader's like/dislike. Keyed by the cleaned URL — the same key recents and
            // the cache use, so reopening an article shows the opinion you left on it.
            guard isShowingReader, let direction = message.body as? String,
                  let rating = TopicPreferences.Rating(rawValue: direction),
                  let source = readerSourceURL else { return }
            // Terms come from the headline; without one there is nothing to learn.
            guard let title = readerArticleTitle, !title.isEmpty else { return }
            var topics = ReaderStore.topics(store: store)
            let now = topics.setRating(rating, title: title,
                                       url: URLCleaner.clean(source).absoluteString)
            ReaderStore.setTopics(topics, store: store)
            let value = now.map { "'\($0.rawValue)'" } ?? "null"
            webView.evaluateJavaScript("window.readerSetRating && window.readerSetRating(\(value))")
        case "readerOpenURL":
            // The start page's field, normalized like the clipboard command so bare
            // "example.com/x" works.
            guard isShowingStartPage, let raw = message.body as? String else { return }
            guard let url = WebURL.clipboardURL(from: raw), openIncoming(url) else {
                services.reject()
                webView.evaluateJavaScript("window.readerURLRejected && window.readerURLRejected()")
                return
            }
        default:
            break
        }
    }

    /// Reads the generator marker of a restored `loadHTMLString` document (back/forward onto
    /// the start or settings page) and re-establishes its flag. Without this the page is on
    /// screen with every one of its message handlers gated shut.
    @MainActor
    func remarkOwnPage() {
        webView.evaluateJavaScript(Self.generatorScript) { @MainActor [weak self] result, _ in
            guard let self else { return }
            let generator = (result as? String) ?? ""
            self.pageState.restored(generator: generator)
            // Same reasoning as the other two restore paths: reused bytes carry the settings
            // they were rendered with. Harmless where the page defines no hook.
            self.pushSettings()
            if self.pageState.isShowingStartPage { self.loadSuggestions() }
        }
    }

    /// The `<meta name="generator">` content of the current document, or "" — how a restored
    /// page says which of ours it is.
    static let generatorScript =
        "(document.querySelector('meta[name=\"generator\"]')||{}).content || ''"

    /// Tells the reader page which rating to draw for `url`. Used when a restored (back or
    /// forward) document's baked-in state may be out of date.
    func pushRating(for url: URL) {
        let rating = ReaderStore.topics(store: store).rating(for: URLCleaner.clean(url).absoluteString)
        let value = rating.map { "'\($0.rawValue)'" } ?? "null"
        webView.evaluateJavaScript(
            "window.readerSetRating && window.readerSetRating(\(value), true)")
    }

    /// Hands a restored document the settings as they now stand. Its `s` was baked when it
    /// was rendered, so without this the next Aa interaction posts those values back over
    /// anything the settings page changed in between — and `data-thumbs` would keep showing
    /// the switch as it was, which for images-off means fetching what the user declined.
    @MainActor
    func pushSettings() {
        let json = ReaderStore.settings(store: store).json
        webView.evaluateJavaScript(
            "window.readerSetSettings && window.readerSetSettings(\(json))")
    }

    /// Stores a resolved source and tells the settings page to show its row.
    @MainActor
    func addSource(_ source: FeedSource) {
        guard isShowingSettings else { return }
        var settings = ReaderStore.suggestions(store: store)
        let languagesBefore = settings.availableLanguages
        guard settings.add(source) else {
            // `add` refuses a duplicate and a full list; saying the wrong one is worse than
            // saying nothing, so tell them apart.
            rejectSource(message: settings.sources.count >= SuggestionSettings.limit
                ? "That is as many sources as this list holds (\(SuggestionSettings.limit))."
                : "That source is already in the list.")
            return
        }
        ReaderStore.setSuggestions(settings, store: store)
        // The language section only exists once two languages are in play, and it's built in
        // Swift — crossing that line is the one case the page can't update in place.
        if languagesBefore.count < 2, settings.availableLanguages.count >= 2 {
            showSettingsPage()
            return
        }
        let row = ["title": source.title, "url": source.url, "language": source.language as Any]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: []) else { return }
        webView.evaluateJavaScript(
            "window.readerSourceAdded && window.readerSourceAdded(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")
    }

    /// Re-enables the settings page's add form with an inline message.
    @MainActor
    func rejectSource(message: String = "No feed found at that address.") {
        guard isShowingSettings else { return }
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "window.readerSourceRejected && window.readerSourceRejected('\(escaped)')")
    }
}
