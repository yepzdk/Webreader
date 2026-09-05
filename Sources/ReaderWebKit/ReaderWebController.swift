import Foundation
import WebKit
import ReaderKit

/// The reader, as a `WKWebView` and the state around it: it receives links, loads them, and
/// swaps articles for the reader rendering. Reader logic is `ReaderKit`; this is the WebKit
/// orchestration, shared by the AppKit and UIKit shells because WebKit is the same framework
/// on both. What differs between them — a menu bar, a beep, a folder picker — is the shell's,
/// and reaches this class through `ReaderHostServices`.
///
/// One copy rather than two: the seventeen script messages, the page-state gates and the
/// extraction flow are subtle enough that the GTK host, which necessarily reimplements them,
/// has already drifted on `isShowingFallback`. A third and fourth copy would drift the same
/// way, silently, since none of it is reachable from the test target.
public final class ReaderWebController: NSObject, WKNavigationDelegate, WKUIDelegate,
                                        WKScriptMessageHandler {
    /// The view the shell puts on screen. Own pages must be loaded through this class (see
    /// `loadOwnPage`) so the page state and the loading cover stay in step; navigating it
    /// directly to a site is fine, and is what `openIncoming` does.
    public let webView: WKWebView

    let store: KeyValueStore
    let cache: ArticleCache
    let appName: String
    let platform: Platform
    unowned let services: ReaderHostServices

    /// The plain "Loading" screen. Set by the shell once the view hierarchy exists, so it is
    /// a var rather than an init argument; a host without one still works.
    public var loadingCover: ReaderLoadingCover?

    /// Sync (issue #7), or nil on a host that has none yet — in which case the settings page
    /// leaves the section out, exactly as it does on Linux.
    public var sync: ReaderSyncBridge?

    /// Our generated pages post here: the offline page's Try Again, the reader's Aa, recents
    /// and hidden-text popovers, its floating Hide-text button, and the start page's URL
    /// field. Spelled once in ReaderKit's page scripts and once here; rename together.
    static let messageNames = [
        "readerRetry", "readerSettings", "readerOpen", "readerClear", "readerOpenURL",
        "readerHide", "readerUnhide", "readerOpenSettings", "readerHome",
        "readerAddSource", "readerRemoveSource", "readerSetLanguages",
        "readerBlockHost", "readerUnblockHost", "readerTopicFeedback",
        "readerRate", "readerOpenSync",
    ]

    /// Which of our own documents is on screen. Tracked explicitly rather than inferred
    /// from `webView.url` (whose value after `loadHTMLString` isn't something to depend
    /// on); the flags also gate the script message handlers, so only our pages — never a
    /// live site — can post to them.
    /// The generated-page state machine (`ReaderKit.PageState`), which owns the transition
    /// rules — they are subtle enough to have shipped a bug in 0.10.0, and living in
    /// ReaderKit is what makes them testable. These two stay as computed flags so the many
    /// gates reading them are unchanged.
    var pageState = PageState()
    var isShowingStartPage: Bool { pageState.isShowingStartPage }
    var isShowingSettings: Bool { pageState.isShowingSettings }
    var isShowingFallback = false
    /// Set by `loadOwnPage` and consumed by the next `didStartProvisionalNavigation`: one of
    /// our own documents is already the answer, so its load must not raise the cover again.
    /// A one-shot rather than a test over the page flags — the flags differ per own page
    /// (the offline page sets none of them), and enumerating them is how a page gets stuck
    /// behind "Loading".
    var coverSuppressedOnce = false
    /// The URL whose load produced the offline page, so Try Again retries *that*
    /// navigation rather than going home.
    var failedURL: URL?

    /// Reader state. `isShowingReader`: the reader rendering is on screen (the swap is a
    /// `loadHTMLString`, not a navigation). `suppressReaderOnce`: set when toggling back to
    /// the original page so its load isn't immediately re-extracted. `enterReaderForURL`:
    /// the URL a recents row asked for — a URL rather than a bool so the request can't leak
    /// onto an unrelated page. `pendingReaderRender`: set between `loadHTMLString`-ing the
    /// reader document and its `didFinish`, so that load is marked as the reader instead
    /// of being re-extracted. `readerSourceURL`: what the current rendering was extracted
    /// from; the reader toggle loads it to get back to the original page.
    var isShowingReader = false
    var suppressReaderOnce = false
    var enterReaderForURL: URL?
    var pendingReaderRender = false
    /// Set when the render about to happen is the offline fallback's saved copy, so its
    /// `didFinish` skips the suggestion fetch. The network just failed, the fetch would fail
    /// too, and `FeedFetcher` caches an empty result for its whole TTL — one offline article
    /// would otherwise leave every list empty for ten minutes.
    var suggestionsSuppressedOnce = false
    var readerSourceURL: URL?
    /// The title of the article currently rendered, so a like/dislike learns terms from the
    /// headline rather than from the URL. Set when the reader renders, and cleared when
    /// back/forward restores a reader document until that page's own title is read back —
    /// rating with a stale title would file one article's terms under another's URL.
    /// Only ever consulted while `isShowingReader`.
    var readerArticleTitle: String?

    /// The suggestion sources' fetcher, and the in-flight ranking for the start page.
    /// Suggestions are strictly best-effort: the start page renders without them and the
    /// task is cancelled the moment the page goes away.
    let feeds = FeedFetcher()
    var suggestionTask: Task<Void, Never>?

    /// `userAgentApplicationName` is the shell's, because the string is a claim about the
    /// system: WKWebView's stock UA lacks the "Version/x Safari/x" suffix, which UA-sniffing
    /// sites read as an ancient or unknown browser ("this browser is no longer supported").
    public init(store: KeyValueStore,
                cache: ArticleCache,
                appName: String,
                platform: Platform,
                userAgentApplicationName: String,
                services: ReaderHostServices) {
        self.store = store
        self.cache = cache
        self.appName = appName
        self.platform = platform
        self.services = services

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        #if os(macOS)
        // Without this, Tab in a WKWebView visits text fields and nothing else: every button,
        // link, recents row and popover control is skipped, so the start page has exactly one
        // tab stop and no focus ring is ever drawn. It defaults to NO, and macOS's own Full
        // Keyboard Access is off by default too, so the app has to ask — this is not something
        // to leave to the reader's system settings. WebKitGTK's counterpart
        // (`enable-tabs-to-links`) already defaults to TRUE, which is why Linux behaves and
        // macOS does not (#26). There is no iOS counterpart: the property is AppKit-era API.
        config.preferences.tabFocusesLinks = true
        #endif
        config.applicationNameForUserAgent = userAgentApplicationName
        webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        for name in Self.messageNames {
            config.userContentController.add(self, name: name)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Debug builds only, so Safari's Develop menu can inspect the running app. Every
        // page in this app is generated Swift string, which means a layout question about a
        // real window ("is this rule applying?") otherwise has no answer short of rebuilding
        // with a guess in it. `Scripts/build-app.sh` builds *release* by default, so this
        // is off in the bundle you normally run: `CONFIG=debug Scripts/build-app.sh` is what
        // produces an inspectable one.
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, *) { webView.isInspectable = true }
        #endif
    }

    deinit {
        for name in Self.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    /// First page. A URL means the app was launched by a link; otherwise — or if that link
    /// turns out not to be one the app can open — the start page.
    public func start(initialURL: URL?) {
        if let initialURL, openIncoming(initialURL) { return }
        showStartPage()
    }

    // MARK: - Commands

    /// In the reader, Reload fetches the source page again — which re-extracts and refreshes
    /// the cached copy. Reloading the rendered document itself would change nothing.
    public func reload() {
        if isShowingReader, let source = readerSourceURL {
            webView.load(URLRequest(url: source))
        } else {
            webView.reload()
        }
    }

    public func toggleReader() {
        if isShowingReader {
            // Back to the original page; its load must not immediately re-enter.
            suppressReaderOnce = true
            isShowingReader = false
            if let source = readerSourceURL {
                webView.load(URLRequest(url: source))
            } else {
                webView.reload()
            }
        } else {
            guard let url = webView.url else { services.reject(); return }
            enterReader(from: url, manual: true)
        }
    }

    /// Whether the reader toggle has anything to act on: a real web page, since the start
    /// and offline pages aren't articles.
    public var canToggleReader: Bool {
        guard let url = webView.url else { return false }
        return WebURL.isWebURL(url)
    }

    /// Stock appearance; history is left alone, and so is zoom, which is the shell's (it has
    /// no cross-platform API). Whatever generated page is up is redrawn with the defaults —
    /// the reader by reloading its source, which auto-enters.
    public func resetAppearance() {
        ReaderStore.resetAppearance(store: store)
        sync?.localStateChanged()
        if isShowingStartPage {
            showStartPage()
        } else if isShowingSettings {
            showSettingsPage()
        } else if isShowingReader, let source = readerSourceURL {
            webView.load(URLRequest(url: source))
        }
    }

    // MARK: - Reader

    /// Runs the Readability extraction on the page at `url` (the one that just finished
    /// loading) and, on success, caches the article and loads the reader rendering as its
    /// OWN document (baseURL = the article, so relative image URLs resolve). A new document
    /// rather than an in-place DOM swap, because the article page's still-running JS must
    /// die with its page — hydrating sites were reverting in-place swaps within a second.
    /// Failure leaves the page untouched: a rejection for a manual request, silence for the
    /// automatic path — never an error page.
    func enterReader(from url: URL, manual: Bool) {
        let hidden = ReaderStore.hiddenPhrases(store: store)
        webView.evaluateJavaScript(Reader.extractionScript(hiding: hidden)) { [weak self] result, _ in
            guard let self else { return }
            // Back/forward landed on one of our own reader documents: it IS the reader, so
            // just say so. Nothing to extract, record, or cache.
            if result as? String == Reader.ownPageSentinel {
                self.loadingCover?.hide()
                self.isShowingReader = true
                self.readerSourceURL = url
                // Back/forward landed here rather than `renderReader`, so the title from the
                // last rendering belongs to a different article. Drop it immediately — a
                // rating clicked before the lookup returns must learn nothing rather than
                // learn the previous headline's terms — then fill it in for THIS page only,
                // since a newer navigation may land while the lookup is in flight.
                self.readerArticleTitle = nil
                self.webView.evaluateJavaScript("document.title") { title, _ in
                    guard self.readerSourceURL == url else { return }
                    self.readerArticleTitle = (title as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // The restored document still shows the rating baked in when it was first
                // rendered; it may have changed since.
                self.pushRating(for: url)
                // Reused bytes, not a fresh render: its settings are as old as the document,
                // and its popover's suggested group was filled by a script call on the way in
                // that this navigation did not repeat (#33).
                self.pushSettings()
                self.loadSuggestions()
                return
            }
            // Extraction takes a moment; if a navigation started meanwhile, `webView.url` is
            // already the new (provisional) URL and this result belongs to a page nobody
            // wants any more — rendering it would file page A's body under page B's key.
            guard self.webView.url == url else { return }
            guard let article = Reader.decode(result) else {
                // Not an article. The site itself is the honest answer, so reveal it.
                self.loadingCover?.hide()
                if manual { self.services.reject() }
                return
            }
            // Only a live extraction has something new to write; cache hits re-render as-is.
            self.cache.store(article, for: URLCleaner.clean(url))
            self.renderReader(article, source: url)
        }
    }

    /// Shows `article` as the reader document and records it in recents. `source` is the
    /// article page (the baseURL, so relative images resolve). The single funnel for live
    /// extractions and cache hits, so page state is reset here and nowhere else; the cache
    /// is pruned here too, because recents — which it mirrors — change here.
    func renderReader(_ article: Article, source: URL) {
        isShowingFallback = false
        pageState.clear()
        failedURL = nil
        readerSourceURL = source
        readerArticleTitle = article.title
        // Record before rendering so the article being opened is the panel's top row.
        // The cleaned URL, because opening a row routes through `openIncoming`, which
        // cleans — recording the raw one would make the replay look like a new article.
        var history = ReaderStore.history(store: store)
        let key = URLCleaner.clean(source).absoluteString
        history.record(title: article.title, url: key, image: article.image)
        ReaderStore.setHistory(history, store: store)
        sync?.localStateChanged()
        cache.prune(keeping: history.entries.map(\.url))
        let html = ReaderPage.html(article: article,
                                   settings: ReaderStore.settings(store: store),
                                   history: history,
                                   hidden: ReaderStore.hiddenPhrases(store: store),
                                   rating: ReaderStore.topics(store: store).rating(for: key),
                                   currentURL: key,
                                   platform: platform)
        pendingReaderRender = true
        loadOwnPage(html, baseURL: source)
    }

    // MARK: - Incoming URLs

    /// Routes an incoming URL: cleans it (tracking redirects unwrapped, tracking params
    /// stripped — so the app never contacts a tracking host, which may be blocked), ignores
    /// non-web URLs, and loads the rest. Returns whether it was accepted.
    @discardableResult
    public func openIncoming(_ url: URL) -> Bool {
        let url = URLCleaner.clean(url)
        guard WebURL.isWebURL(url) else { return false }
        isShowingFallback = false
        pageState.clear()
        failedURL = nil
        webView.load(URLRequest(url: url))
        services.bringToFront()
        return true
    }

    /// Loads one of our own generated documents. The single place `loadHTMLString` is called
    /// (mirroring the GTK host's `loadHTML`), which is what gives the loading cover one place
    /// to come down: every own page — reader, start, settings, offline — settles here.
    func loadOwnPage(_ html: String, baseURL: URL?) {
        loadingCover?.hide()
        coverSuppressedOnce = true
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// The start page: URL field, recents, and the appearance controls — reading the same
    /// persisted settings as the reader page.
    public func showStartPage() {
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.startPage)
        sync?.startPageShown()
        loadOwnPage(StartPage.html(appName: appName,
                                   settings: ReaderStore.settings(store: store),
                                   history: ReaderStore.history(store: store),
                                   platform: platform),
                    baseURL: nil)
    }

    /// The settings page: the suggestion sources and their language filter.
    public func showSettingsPage() {
        suggestionTask?.cancel()
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.settings)
        loadOwnPage(SettingsPage.html(appName: appName,
                                      settings: ReaderStore.settings(store: store),
                                      suggestions: ReaderStore.suggestions(store: store),
                                      hidden: ReaderStore.hiddenPhrases(store: store),
                                      platform: platform,
                                      syncFolder: sync?.folderDisplayPath,
                                      syncSummary: sync?.summary ?? ""),
                    baseURL: nil)
    }

    // MARK: - Suggestions

    /// Fetches the sources, ranks them against what's been read, and hands the result to
    /// whichever of our pages shows suggestions — the start page's list, or the reader's
    /// recents popover (#33). Everything here is best-effort: the fetch and ranking run off
    /// the main actor inside the task, and the page is already on screen and stays usable
    /// whatever happens. Main-actor isolated because it reads the page flags and hands off to
    /// the web view; every caller is already on the main thread.
    @MainActor
    func loadSuggestions() {
        suggestionTask?.cancel()
        let settings = ReaderStore.suggestions(store: store)
        // No sources is precisely when the page's "add a source" empty state should show,
        // so tell the page that rather than leaving the section hidden.
        guard !settings.sources.isEmpty else {
            showSuggestions([])
            return
        }
        let history = ReaderStore.history(store: store)
        let topics = ReaderStore.topics(store: store)
        let cache = cache
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.feeds.items(for: settings.sources)
            guard !Task.isCancelled else { return }
            // The profile is the recent articles' own text, straight from the cache. A row
            // whose body has fallen out of the cache (it's a Caches folder, and history
            // predating the cache has none) still contributes its title — a weaker signal
            // than the full text, but far better than dropping the article from the profile.
            let read = history.entries.map { entry in
                URL(string: entry.url).flatMap { cache.article(for: $0) }
                    ?? Article(title: entry.title, byline: nil, siteName: nil, content: "")
            }
            let ranked = Suggestions.rank(items, read: read,
                                          readURLs: Set(history.entries.map(\.url)),
                                          languages: settings.languages,
                                          blockedHosts: settings.blockedHosts,
                                          topics: topics)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.showSuggestions(ranked) }
        }
    }

    @MainActor
    func showSuggestions(_ items: [FeedItem]) {
        // The page may have been replaced while the feeds were in flight. Both surfaces
        // implement `readerSetSuggestions`; each renders the shape that fits it.
        guard isShowingStartPage || isShowingReader else { return }
        let rows: [[String: String]] = items.map { item in
            var row = ["title": item.title, "url": item.url, "source": item.host]
            if let image = item.image { row["image"] = image }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else { return }
        webView.evaluateJavaScript(
            "window.readerSetSuggestions && window.readerSetSuggestions(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")
    }

    // MARK: - Sync

    /// Applies what a sync cycle merged in. Both halves update the page in place rather
    /// than re-rendering it: the start page holds a URL field, and re-rendering under
    /// someone mid-sentence throws their typing away.
    @MainActor
    public func applySync(_ result: SyncEngine.Result) {
        guard isShowingReader || isShowingStartPage || isShowingSettings else { return }
        if result.changedSettings {
            let settings = ReaderStore.settings(store: store)
            webView.evaluateJavaScript(
                "window.readerApplySettings && window.readerApplySettings(\(HTML.jsLiteral(settings.json)))")
        }
        guard result.changedHistory else { return }
        let history = ReaderStore.history(store: store)
        // The cache mirrors recents: a merge that dropped rows (a clear on another device)
        // has to drop their saved copies too.
        cache.prune(keeping: history.entries.map(\.url))
        let rows = history.entries.map { ["title": $0.title, "url": $0.url] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [])
        else { return }
        webView.evaluateJavaScript(
            "window.readerSetRecents && window.readerSetRecents(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")
    }

    /// Sync's state changed (a folder chosen, a cycle landed, an error): redraw whatever is
    /// showing it. Pushed, not re-rendered — the settings page holds a half-typed feed
    /// address that has to survive someone setting sync up.
    @MainActor
    public func syncStatusChanged() {
        guard isShowingSettings, let sync else { return }
        // A folder path is whatever the user named their folders; it takes the same escaping
        // route as feed titles rather than being spliced into the script by hand.
        let arguments: [Any] = [sync.folderDisplayPath ?? NSNull(), sync.summary]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [])
        else { return }
        webView.evaluateJavaScript(
            "window.readerSetSyncStatus && window.readerSetSyncStatus.apply(null, "
                + HTML.jsLiteral(String(decoding: data, as: UTF8.self)) + ")")
    }
}
