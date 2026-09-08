import Foundation

/// What a host must do next. The reader's whole side of the conversation, as values.
///
/// The commands exist because the third host is not Swift's to drive: Android's WebView is
/// reached from Kotlin over JNI, and a session that called back into its host mid-cycle
/// would need upcalls on every message. Returning a list instead makes the reader a
/// function — which is also why it can be tested without a web view at all.
public enum ReaderCommand: Equatable, Sendable {
    /// Navigate to someone else's page.
    case load(URL)
    /// Show one of ours. `baseURL` is the article for a reader render, so relative image
    /// URLs resolve; nil for the start, settings and offline pages.
    case show(html: String, baseURL: URL?)
    /// Run script in the page. Used only for the `window.reader*` hooks, whose results the
    /// reader never reads.
    case evaluate(String)
    /// Run the extraction script against the page at `url` and hand the result back to
    /// `extractionResult(url:result:title:)`. Separate from `evaluate` because the answer
    /// is the point.
    case extract(url: URL, script: String)
    /// The app said no: a beep on a Mac, a haptic on a phone. The only feedback these paths
    /// have, so a host that drops it makes the refusals invisible.
    case reject
    /// A scheme the web view cannot render — hand it to whatever owns it.
    case openExternally(URL)
    /// The settings page asked for sync setup; the folder picker is native on every host.
    case presentSyncSetup
    /// Rank the feeds and come back through `suggestions()`. Best-effort and cancellable:
    /// the page is already on screen and stays usable whatever happens.
    case fetchSuggestions
    /// Look this feed address up and come back through `resolveSource(_:)`. The settings
    /// page has disabled its add button and is waiting for one of the two answers.
    case resolveSource(URL)
}

/// The reader, with the web view taken out of it.
///
/// Everything that decides *what the reader does* lives here: which of our pages is on
/// screen, when a page is offered to Readability, what each of the seventeen script
/// messages means, and what to draw afterwards. What is left for a host is running the
/// commands this hands back — and that part is small enough to write three times without
/// the three drifting.
///
/// Not thread-safe and not meant to be: a host either drives it from one thread or
/// serialises its calls, and the two things that genuinely run elsewhere — fetching the
/// feeds and resolving one — are `async` methods that reach no session state at all.
/// Everything they need arrives as a value, and the caller applies what they answer.
public final class ReaderSession {
    /// The `<meta name="generator">` content a restored document identifies itself by.
    /// Hosts read it with this script and pass the answer to `navigationFinished`.
    public static let generatorScript =
        "(document.querySelector('meta[name=\"generator\"]')||{}).content || ''"

    /// The reader's persisted state and the saved articles beside it. Public because a host
    /// pushes merged state into a page without going through the session — sync's business,
    /// not the reader's.
    public let store: KeyValueStore
    public let cache: ArticleCache
    let appName: String
    let platform: Platform
    let palette: ReaderPalette?

    /// Sync, as the settings page shows it — nil on a host that has none yet, which is what
    /// an empty summary already means to the page. Set through `syncStatus(folder:summary:)`
    /// so a change reaches a settings page that is already on screen.
    public internal(set) var syncFolderDisplayPath: String?
    public internal(set) var syncSummary: String?
    /// Asked for the current status just before the settings page renders. The summary is
    /// relative to now ("Last synced a few minutes ago"), so the copy `syncStatus` left
    /// behind is only accurate at the moment it arrived — and `readerOpenSettings` renders
    /// that page without the host getting a word in.
    public var syncStatusProvider: (() -> (folder: String?, summary: String))?
    /// Called when a message changed something the other devices should see. The host
    /// debounces and schedules; the session only knows that it happened.
    public var onLocalStateChanged: (() -> Void)?
    /// Called when the start page comes up — a good moment to pull, since recents are what
    /// it shows.
    public var onStartPageShown: (() -> Void)?

    /// Which of our own documents is on screen. `PageState` owns the transition rules; they
    /// are subtle enough to have shipped a bug, and living in a tested type is what keeps
    /// them honest.
    public private(set) var pageState = PageState()
    var isShowingStartPage: Bool { pageState.isShowingStartPage }
    var isShowingSettings: Bool { pageState.isShowingSettings }
    public internal(set) var isShowingFallback = false
    /// The URL whose load produced the offline page, so Try Again retries *that* navigation
    /// rather than going home.
    var failedURL: URL?

    /// Reader state. `isShowingReader`: the reader rendering is on screen (the swap is a
    /// document load, not a navigation). `suppressReaderOnce`: set when toggling back to the
    /// original page so its load isn't immediately re-extracted. `enterReaderForURL`: the URL
    /// a recents row asked for — a URL rather than a bool so the request can't leak onto an
    /// unrelated page. `pendingReaderRender`: set between showing the reader document and its
    /// load finishing, so that load is marked as the reader instead of being re-extracted.
    public private(set) var isShowingReader = false
    var suppressReaderOnce = false
    var enterReaderForURL: URL?
    var pendingReaderRender = false
    /// Set when the render about to happen is the offline fallback's saved copy, so its
    /// finish skips the suggestion fetch. The network just failed, the fetch would fail too,
    /// and `FeedFetcher` caches an empty result for its whole TTL — one offline article would
    /// otherwise leave every list empty for ten minutes.
    var suggestionsSuppressedOnce = false
    var readerSourceURL: URL?
    /// The title of the article currently rendered, so a like/dislike learns terms from the
    /// headline rather than from the URL. Cleared when a restored reader document arrives
    /// until that page's own title is read back — rating with a stale title would file one
    /// article's terms under another's URL.
    var readerArticleTitle: String?

    let feeds = FeedFetcher()

    public init(store: KeyValueStore, cache: ArticleCache, appName: String,
                platform: Platform, palette: ReaderPalette? = nil) {
        self.store = store
        self.cache = cache
        self.appName = appName
        self.platform = platform
        self.palette = palette
    }

    // MARK: - Entry points

    /// First page. A URL means the app was launched by a link; otherwise — or if that link
    /// turns out not to be one the app can open — the start page.
    public func start(initialURL: URL?) -> [ReaderCommand] {
        if let initialURL {
            let opened = openIncoming(initialURL)
            if opened.accepted { return opened.commands }
        }
        return showStartPage()
    }

    /// Routes an incoming URL: cleans it (tracking redirects unwrapped, tracking params
    /// stripped — so the app never contacts a tracking host, which may be blocked), ignores
    /// non-web URLs, and loads the rest.
    public func openIncoming(_ url: URL) -> (accepted: Bool, commands: [ReaderCommand]) {
        let url = URLCleaner.clean(url)
        guard WebURL.isWebURL(url) else { return (false, []) }
        isShowingFallback = false
        pageState.clear()
        failedURL = nil
        return (true, [.load(url)])
    }

    /// Whatever another app shared: a bare link, or a link with a headline wrapped around it.
    ///
    /// `WebURL.sharedURL` rather than `clipboardURL`, and the difference is deliberate — a
    /// share hands over a link, while a paste of prose is more likely a mis-paste than an
    /// invitation to go hunting in it.
    public func openShared(_ text: String) -> (accepted: Bool, commands: [ReaderCommand]) {
        guard let url = WebURL.sharedURL(from: text) else { return (false, []) }
        return openIncoming(url)
    }

    /// Whether the web view should load this itself, or hand it to whatever owns the scheme.
    ///
    /// Exposed because a host cannot be trusted to remember the whole list: `about:` and
    /// `data:` are ours as much as `http` is, and a host that checks only for http/https
    /// sends its own generated pages to another app.
    public func loadsInApp(_ url: URL) -> Bool { WebURL.loadsInApp(url) }

    public func home() -> [ReaderCommand] { showStartPage() }

    /// In the reader, reloading fetches the source page again — which re-extracts and
    /// refreshes the cached copy. Reloading the rendered document would change nothing, so
    /// a host with no source to go back to reloads whatever is on screen itself.
    public func reload() -> [ReaderCommand] {
        if isShowingReader, let source = readerSourceURL { return [.load(source)] }
        return []
    }

    /// Toggles between the reader and the page it came from. `currentURL` is what the web
    /// view has loaded, which only the host knows.
    public func toggleReader(currentURL: URL?) -> [ReaderCommand] {
        if isShowingReader {
            // Back to the original page; its load must not immediately re-enter.
            suppressReaderOnce = true
            isShowingReader = false
            if let source = readerSourceURL { return [.load(source)] }
            return []
        }
        guard let currentURL, WebURL.isWebURL(currentURL) else { return [.reject] }
        // Asked for by name, so a page that does not extract has to say so: the beep is the
        // only answer this path has ever had.
        requestedExtraction = true
        return [extractCommand(for: currentURL)]
    }

    /// Stock appearance; history is left alone, and so is zoom, which is the host's — it has
    /// no cross-platform API. Whatever generated page is up is redrawn with the defaults, the
    /// reader by reloading its source, which auto-enters.
    public func resetAppearance() -> [ReaderCommand] {
        ReaderStore.resetAppearance(store: store)
        onLocalStateChanged?()
        if isShowingStartPage { return showStartPage() }
        if isShowingSettings { return showSettingsPage() }
        if isShowingReader, let source = readerSourceURL { return [.load(source)] }
        return []
    }

    // MARK: - Navigation

    /// A new navigation means whatever it lands on is a fresh page, not our reader
    /// rendering — except the reader document's own load, marked by `pendingReaderRender`.
    public func navigationStarted() {
        if !pendingReaderRender { isShowingReader = false }
        // Our generated pages are real history entries, so back/forward can navigate AWAY
        // from one without going through any of the paths that reset these flags — left set,
        // they gate every message handler against the page actually on screen. But a
        // document load fires this too, and the load the app just started must not clear the
        // flag it just set. `PageState` owns that distinction, and is tested on it.
        pageState.navigationStarted()
    }

    /// Every real page that finishes loading is offered to the reader; pages that don't
    /// extract stay as they are. `generator` is the `<meta name="generator">` content the
    /// host read from the finished document, empty when there is none — it is how a
    /// back/forward restore of one of our own documents is recognised, since those carry no
    /// URL of their own.
    public func navigationFinished(url: URL?, generator: String) -> [ReaderCommand] {
        if pendingReaderRender {
            pendingReaderRender = false
            isShowingReader = true
            // The article is up; its popover's suggested group catches up when it can.
            // Usually free — arriving from the start page leaves the feeds warm in
            // `FeedFetcher`'s cache — but a link opened from another app fetches here.
            if suggestionsSuppressedOnce {
                suggestionsSuppressedOnce = false
                return []
            }
            return [.fetchSuggestions]
        }
        if suppressReaderOnce {
            suppressReaderOnce = false
            // The reader toggle asked for the original page; showing it is the whole point.
            return []
        }
        // Our own start/settings load has landed; the page it set still stands.
        if let own = pageState.navigationFinished() {
            return own == .startPage ? [.fetchSuggestions] : []
        }
        // A recents row asked for this page explicitly — it rejects audibly if extraction
        // fails, since the user asked for that article. Any finished load consumes the
        // request.
        let requested = enterReaderForURL != nil && enterReaderForURL == url
        enterReaderForURL = nil
        var commands: [ReaderCommand] = []
        // The start page is up and interactive; the suggestions catch up when they can.
        if isShowingStartPage { commands.append(.fetchSuggestions) }
        guard !isShowingReader, !isShowingFallback, !isShowingStartPage, !isShowingSettings
        else { return commands }
        // Anything that isn't a real web page here is a restore of one of our own documents,
        // so believe what the document says it is rather than trying to extract it.
        guard let url, WebURL.isWebURL(url) else {
            return commands + restored(generator: generator)
        }
        // A real web page is offered to the reader whatever its generator marker claims. Our
        // own documents have no URL of their own and never reach this line, so a page that
        // says it was generated by the start page is a site asking for the handlers that page
        // is trusted with — including `readerClear`, which tombstones recents on every other
        // device. The reader's own restored document is recognised by the extraction script's
        // sentinel instead, which a site cannot forge without being an article anyway.
        requestedExtraction = requested
        return commands + [extractCommand(for: url)]
    }

    /// Whether the extraction now in flight was asked for by name — a recents row, or the
    /// reader toggle — and should therefore say so when it fails.
    private var requestedExtraction = false

    /// Re-establishes a restored document's page state from its generator marker. Without
    /// this the page is on screen with every one of its message handlers gated shut.
    private func restored(generator: String) -> [ReaderCommand] {
        pageState.restored(generator: generator)
        // Reused bytes carry the settings they were rendered with. Harmless where the page
        // defines no hook.
        var commands: [ReaderCommand] = [pushSettings()]
        if pageState.isShowingStartPage { commands.append(.fetchSuggestions) }
        return commands
    }

    private func extractCommand(for url: URL) -> ReaderCommand {
        .extract(url: url, script: Reader.extractionScript(hiding: ReaderStore.hiddenPhrases(store: store)))
    }

    /// What the extraction script returned for `url`, plus that document's title. The title
    /// travels with the result because the one path that needs it — a restored reader
    /// document, whose baked-in title belongs to whatever was rendered last — would
    /// otherwise cost a second round trip through the host.
    public func extractionResult(url: URL, result: String?, title: String?) -> [ReaderCommand] {
        let requested = requestedExtraction
        requestedExtraction = false
        // A restore landed on one of our own reader documents: it IS the reader, so just say
        // so. Nothing to extract, record, or cache.
        if result == Reader.ownPageSentinel {
            isShowingReader = true
            readerSourceURL = url
            readerArticleTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The restored document still shows the rating baked in when it was first
            // rendered; it may have changed since. And its settings are as old as it is,
            // while its popover's suggested group was filled by a script call on the way in
            // that this navigation did not repeat.
            return [pushRating(for: url, silent: true), pushSettings(), .fetchSuggestions]
        }
        guard let article = Reader.decode(result) else {
            // Not an article. The site itself is the honest answer, so reveal it.
            return requested ? [.reject] : []
        }
        // Only a live extraction has something new to write; cache hits re-render as-is.
        cache.store(article, for: URLCleaner.clean(url))
        return renderReader(article, source: url)
    }

    /// Replaces the page with the offline one for a genuine top-level load failure, ignoring
    /// the cancellations and policy interruptions that aren't real errors. `code` is an
    /// `NSURLError` value; hosts whose engine reports something else translate, so
    /// `OfflineFallback.classify` stays one implementation.
    public func loadFailed(url: URL?, code: Int) -> [ReaderCommand] {
        pageState.clear()
        // The load a recents row asked for never arrived; cleared before the ignorable guard
        // because cancelled loads are the likeliest way a row's navigation dies.
        enterReaderForURL = nil
        requestedExtraction = false
        guard !OfflineFallback.isIgnorable(errorCode: code) else { return [] }
        failedURL = url
        // A saved copy beats an error page — the article is what was asked for, and a reload
        // fetches the live page again once the network is back. Not when the user just asked
        // for the ORIGINAL page: then the offline page is the honest answer.
        if !suppressReaderOnce, let url, let cached = cache.article(for: URLCleaner.clean(url)) {
            // The load that just failed is the network answer for this whole render; asking
            // the feeds now only poisons their cache with an empty result.
            suggestionsSuppressedOnce = true
            return renderReader(cached, source: URLCleaner.clean(url))
        }
        let html = OfflineFallback.html(appName: appName, host: url?.host,
                                        kind: OfflineFallback.classify(errorCode: code),
                                        platform: platform, palette: palette)
        isShowingFallback = true
        return [.show(html: html, baseURL: nil)]
    }

    // MARK: - Pages

    /// The start page: URL field, recents, and the appearance controls — reading the same
    /// persisted settings as the reader page.
    public func showStartPage() -> [ReaderCommand] {
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.startPage)
        onStartPageShown?()
        return [.show(html: StartPage.html(appName: appName,
                                           settings: ReaderStore.settings(store: store),
                                           history: ReaderStore.history(store: store),
                                           platform: platform, palette: palette),
                      baseURL: nil)]
    }

    /// The settings page: the suggestion sources and their language filter.
    public func showSettingsPage() -> [ReaderCommand] {
        if let latest = syncStatusProvider?() {
            syncFolderDisplayPath = latest.folder
            syncSummary = latest.summary
        }
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.settings)
        return [.show(html: SettingsPage.html(appName: appName,
                                              settings: ReaderStore.settings(store: store),
                                              suggestions: ReaderStore.suggestions(store: store),
                                              hidden: ReaderStore.hiddenPhrases(store: store),
                                              platform: platform, palette: palette,
                                              syncFolder: syncFolderDisplayPath,
                                              syncSummary: syncSummary ?? ""),
                      baseURL: nil)]
    }

    /// Shows `article` as the reader document and records it in recents. `source` is the
    /// article page. The single funnel for live extractions and cache hits, so page state is
    /// reset here and nowhere else; the cache is pruned here too, because recents — which it
    /// mirrors — change here.
    func renderReader(_ article: Article, source: URL) -> [ReaderCommand] {
        isShowingFallback = false
        pageState.clear()
        failedURL = nil
        readerSourceURL = source
        readerArticleTitle = article.title
        // Record before rendering so the article being opened is the panel's top row. The
        // cleaned URL, because opening a row routes through `openIncoming`, which cleans —
        // recording the raw one would make the replay look like a new article.
        var history = ReaderStore.history(store: store)
        let key = URLCleaner.clean(source).absoluteString
        history.record(title: article.title, url: key, image: article.image)
        ReaderStore.setHistory(history, store: store)
        onLocalStateChanged?()
        cache.prune(keeping: history.entries.map(\.url))
        let html = ReaderPage.html(article: article,
                                   settings: ReaderStore.settings(store: store),
                                   history: history,
                                   hidden: ReaderStore.hiddenPhrases(store: store),
                                   rating: ReaderStore.topics(store: store).rating(for: key),
                                   currentURL: key,
                                   platform: platform, palette: palette)
        pendingReaderRender = true
        return [.show(html: html, baseURL: source)]
    }

    // MARK: - Pushing state into a page

    /// Hands a restored document the settings as they now stand. Its baked-in copy is as old
    /// as the document, so without this the next Aa interaction posts those values back over
    /// anything the settings page changed in between.
    func pushSettings() -> ReaderCommand {
        .evaluate("window.readerSetSettings && window.readerSetSettings(\(ReaderStore.settings(store: store).json))")
    }

    /// Tells the reader page which rating to draw. `silent` for a restore, where the rating
    /// did not just change and a toast would be a lie.
    func pushRating(for url: URL, silent: Bool) -> ReaderCommand {
        let rating = ReaderStore.topics(store: store).rating(for: URLCleaner.clean(url).absoluteString)
        let value = rating.map { "'\($0.rawValue)'" } ?? "null"
        return .evaluate("window.readerSetRating && window.readerSetRating(\(value)\(silent ? ", true" : ""))")
    }
}
