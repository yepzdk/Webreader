import Cocoa
import WebKit
import ReaderKit

/// The single-window reader: a `WKWebView` that receives links (a browser picker like
/// Choosy, `open -a WebReader <url>`, ⇧⌘O, the start page's field), loads them, and swaps
/// articles for the reader rendering. Reader logic is `ReaderKit`; this is the AppKit and
/// WebKit orchestration.
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
                         WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var progressLine: ProgressLine?
    private let store: KeyValueStore = DefaultsStore()
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebReader"

    /// WKWebView's stock UA lacks the "Version/x Safari/x" suffix, which UA-sniffing sites
    /// read as an ancient or unknown browser ("this browser is no longer supported").
    private static let safariApplicationName = "Version/26.0 Safari/605.1.15"

    /// Which of our own documents is on screen. Tracked explicitly rather than inferred
    /// from `webView.url` (whose value after `loadHTMLString` isn't something to depend
    /// on); the flags also gate the script message handlers, so only our pages — never a
    /// live site — can post to them.
    /// The generated-page state machine (`ReaderKit.PageState`), which owns the transition
    /// rules — they are subtle enough to have shipped a bug in 0.10.0, and living in
    /// ReaderKit is what makes them testable. These two stay as computed flags so the many
    /// gates reading them are unchanged.
    private var pageState = PageState()
    private var isShowingStartPage: Bool { pageState.isShowingStartPage }
    private var isShowingSettings: Bool { pageState.isShowingSettings }
    private var isShowingFallback = false
    /// The URL whose load produced the offline page, so Try Again retries *that*
    /// navigation rather than going home.
    private var failedURL: URL?
    /// A URL received before the web view exists (cold launch via a link).
    private var pendingIncomingURL: URL?

    /// Reader state. `isShowingReader`: the reader rendering is on screen (the swap is a
    /// `loadHTMLString`, not a navigation). `suppressReaderOnce`: set when toggling back to
    /// the original page so its load isn't immediately re-extracted. `enterReaderForURL`:
    /// the URL a recents row asked for — a URL rather than a bool so the request can't leak
    /// onto an unrelated page. `pendingReaderRender`: set between `loadHTMLString`-ing the
    /// reader document and its `didFinish`, so that load is marked as the reader instead
    /// of being re-extracted. `readerSourceURL`: what the current rendering was extracted
    /// from; ⇧⌘R loads it to get back to the original page.
    private var isShowingReader = false
    private var suppressReaderOnce = false
    private var enterReaderForURL: URL?
    private var pendingReaderRender = false
    private var readerSourceURL: URL?
    /// The title of the article currently rendered, so a like/dislike learns terms from the
    /// headline rather than from the URL. Set when the reader renders, and cleared when
    /// back/forward restores a reader document until that page's own title is read back —
    /// rating with a stale title would file one article's terms under another's URL.
    /// Only ever consulted while `isShowingReader`.
    private var readerArticleTitle: String?

    /// The suggestion sources' fetcher, and the in-flight ranking for the start page.
    /// Suggestions are strictly best-effort: the start page renders without them and the
    /// task is cancelled the moment the page goes away.
    private let feeds = FeedFetcher()
    private var suggestionTask: Task<Void, Never>?

    /// On-disk copies of the recent articles (see `ArticleCache`): recents rows open from
    /// here, and a failed load falls back to it.
    private let cache = ArticleCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dk.yepz.webreader")
            .appendingPathComponent("articles"))

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The GetURL Apple Event (the older routing path some openers and Choosy
        // configurations use) can arrive before didFinishLaunching, so register now; a
        // URL passed at cold launch is stashed as `pendingIncomingURL`.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyImport.run(into: store)

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = Self.safariApplicationName
        // Our generated pages post here: the offline page's Try Again, the reader's Aa,
        // recents and hidden-text popovers, its floating Hide-text button, and the start
        // page's URL field.
        for name in ["readerRetry", "readerSettings", "readerOpen", "readerClear", "readerOpenURL",
                     "readerHide", "readerUnhide", "readerOpenSettings", "readerHome",
                     "readerAddSource", "readerRemoveSource", "readerSetLanguages",
                     "readerBlockHost", "readerUnblockHost", "readerTopicFeedback", "readerRate"] {
            config.userContentController.add(self, name: name)
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        if !window.setFrameUsingName("WebReaderMainWindow") { window.center() }
        window.setFrameAutosaveName("WebReaderMainWindow")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = ReaderStore.zoom(store: store)
        window.contentView!.addSubview(webView)
        progressLine = ProgressLine(webView: webView, in: window.contentView!)

        // A real main menu is required for the standard editing shortcuts (⌘C/⌘V/⌘X/⌘A)
        // to reach the web content — without it, paste silently does nothing.
        NSApp.mainMenu = buildMainMenu()

        if let pending = pendingIncomingURL {
            pendingIncomingURL = nil
            webView.load(URLRequest(url: pending))
        } else {
            showStartPage()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAbout(_:)), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File: the keyboard path for handing the app a link a browser is already viewing
        // (a browser picker can't intercept those).
        let fileMenu = NSMenu(title: "File")
        mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu
        let openClipboard = fileMenu.addItem(withTitle: "Open URL from Clipboard",
                                             action: #selector(openFromClipboard(_:)), keyEquivalent: "o")
        openClipboard.keyEquivalentModifierMask = [.command, .shift]
        openClipboard.target = self

        // Edit: the standard responder-chain actions that make copy/paste work in the web view.
        let editMenu = NSMenu(title: "Edit")
        mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // The chromeless window has no address bar, so this is how you get the URL out.
        let copyURL = editMenu.addItem(withTitle: "Copy Current URL",
                                       action: #selector(copyCurrentURL(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        copyURL.target = self

        let viewMenu = NSMenu(title: "View")
        mainMenu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r").target = self
        let home = viewMenu.addItem(withTitle: "Home", action: #selector(goHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        home.target = self
        let reader = viewMenu.addItem(withTitle: "Toggle Reader View",
                                      action: #selector(toggleReader(_:)), keyEquivalent: "r")
        reader.keyEquivalentModifierMask = [.command, .shift]
        reader.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+").target = self
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0").target = self
        viewMenu.addItem(withTitle: "Reset Reader Appearance",
                         action: #selector(resetReaderAppearance(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[").target = self
        viewMenu.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]").target = self

        let windowMenu = NSMenu(title: "Window")
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // Enable our self-targeted items only when they can do something.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyCurrentURL(_:)):
            return WebURL.urlToCopy(currentURL: webView?.url) != nil
        case #selector(goBack(_:)):
            return webView?.canGoBack ?? false
        case #selector(goForward(_:)):
            return webView?.canGoForward ?? false
        case #selector(toggleReader(_:)):
            // Needs a real web page (the start page / offline page aren't articles).
            guard let url = webView?.url else { return false }
            return WebURL.isWebURL(url)
        case #selector(openFromClipboard(_:)):
            return WebURL.clipboardURL(from: NSPasteboard.general.string(forType: .string)) != nil
        default:
            return true
        }
    }

    // MARK: - Actions

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Reader view powered by Mozilla Readability \(ReadabilityJS.version)."),
        ])
    }

    /// In the reader, Reload fetches the source page again — which re-extracts and refreshes
    /// the cached copy. Reloading the rendered document itself would change nothing.
    @objc private func reloadPage(_ sender: Any?) {
        if isShowingReader, let source = readerSourceURL {
            webView.load(URLRequest(url: source))
        } else {
            webView.reload()
        }
    }
    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func goForward(_ sender: Any?) { webView.goForward() }
    @objc private func goHome(_ sender: Any?) { showStartPage() }
    @objc private func showSettings(_ sender: Any?) { showSettingsPage() }

    @objc private func openFromClipboard(_ sender: Any?) {
        guard let url = WebURL.clipboardURL(from: NSPasteboard.general.string(forType: .string)),
              openIncoming(url) else {
            NSSound.beep()
            return
        }
    }

    @objc private func copyCurrentURL(_ sender: Any?) {
        guard let url = WebURL.urlToCopy(currentURL: webView.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func zoomIn(_ sender: Any?) { applyZoom(webView.pageZoom + ReaderStore.zoomStep) }
    @objc private func zoomOut(_ sender: Any?) { applyZoom(webView.pageZoom - ReaderStore.zoomStep) }
    @objc private func actualSize(_ sender: Any?) { applyZoom(1.0) }

    private func applyZoom(_ raw: Double) {
        let clamped = ReaderStore.clampZoom(raw)
        webView.pageZoom = clamped
        ReaderStore.setZoom(clamped, store: store)
    }

    /// Stock appearance and zoom; history is left alone. Whatever generated page is up is
    /// redrawn with the defaults — the reader by reloading its source, which auto-enters.
    @objc private func resetReaderAppearance(_ sender: Any?) {
        ReaderStore.resetAppearance(store: store)
        webView.pageZoom = 1.0
        if isShowingStartPage {
            showStartPage()
        } else if isShowingSettings {
            showSettingsPage()
        } else if isShowingReader, let source = readerSourceURL {
            webView.load(URLRequest(url: source))
        }
    }

    // MARK: - Reader

    @objc private func toggleReader(_ sender: Any?) {
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
            guard let url = webView.url else { NSSound.beep(); return }
            enterReader(from: url, manual: true)
        }
    }

    /// Runs the Readability extraction on the page at `url` (the one that just finished
    /// loading) and, on success, caches the article and loads the reader rendering as its
    /// OWN document (baseURL = the article, so relative image URLs resolve). A new document
    /// rather than an in-place DOM swap, because the article page's still-running JS must
    /// die with its page — hydrating sites were reverting in-place swaps within a second.
    /// Failure leaves the page untouched: a beep for a manual request, silence for the
    /// automatic path — never an error page.
    private func enterReader(from url: URL, manual: Bool) {
        let hidden = ReaderStore.hiddenPhrases(store: store)
        webView.evaluateJavaScript(Reader.extractionScript(hiding: hidden)) { [weak self] result, _ in
            guard let self else { return }
            // Back/forward landed on one of our own reader documents: it IS the reader, so
            // just say so. Nothing to extract, record, or cache.
            if result as? String == Reader.ownPageSentinel {
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
                return
            }
            // Extraction takes a moment; if a navigation started meanwhile, `webView.url` is
            // already the new (provisional) URL and this result belongs to a page nobody
            // wants any more — rendering it would file page A's body under page B's key.
            guard self.webView.url == url else { return }
            guard let article = Reader.decode(result) else {
                if manual { NSSound.beep() }
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
    private func renderReader(_ article: Article, source: URL) {
        isShowingFallback = false
        pageState.clear()
        failedURL = nil
        readerSourceURL = source
        readerArticleTitle = article.title
        // Record before rendering so the article being opened is the panel's top row.
        // The cleaned URL, because opening a row routes through `openIncoming`, which
        // cleans — recording the raw one would make the replay look like a new article.
        var history = ReaderStore.history(store: store)
        history.record(title: article.title, url: URLCleaner.clean(source).absoluteString)
        ReaderStore.setHistory(history, store: store)
        cache.prune(keeping: history.entries.map(\.url))
        let html = ReaderPage.html(article: article,
                                   settings: ReaderStore.settings(store: store),
                                   history: history,
                                   hidden: ReaderStore.hiddenPhrases(store: store),
                                   rating: ReaderStore.topics(store: store)
                                       .rating(for: URLCleaner.clean(source).absoluteString))
        pendingReaderRender = true
        webView.loadHTMLString(html, baseURL: source)
    }

    // MARK: - Incoming URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-window model: navigate to the first acceptable URL, ignore the rest.
        for url in urls where openIncoming(url) { return }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        openIncoming(url)
    }

    /// Routes an incoming URL: cleans it (tracking redirects unwrapped, tracking params
    /// stripped — so the app never contacts a tracking host, which may be blocked), ignores
    /// non-web URLs, and loads the rest. Before the web view exists (cold launch), stashes
    /// it for `applicationDidFinishLaunching`. Returns whether it was accepted.
    @discardableResult
    private func openIncoming(_ url: URL) -> Bool {
        let url = URLCleaner.clean(url)
        guard WebURL.isWebURL(url) else { return false }
        if webView == nil {
            pendingIncomingURL = url
        } else {
            isShowingFallback = false
            pageState.clear()
            failedURL = nil
            webView.load(URLRequest(url: url))
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// The start page: URL field, recents, and the appearance controls — reading the same
    /// persisted settings as the reader page.
    private func showStartPage() {
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.startPage)
        webView.loadHTMLString(StartPage.html(appName: appName,
                                              settings: ReaderStore.settings(store: store),
                                              history: ReaderStore.history(store: store),
                                              hidden: ReaderStore.hiddenPhrases(store: store)),
                               baseURL: nil)
    }

    /// The settings page: the suggestion sources and their language filter.
    private func showSettingsPage() {
        suggestionTask?.cancel()
        isShowingFallback = false
        failedURL = nil
        pageState.willShow(.settings)
        webView.loadHTMLString(SettingsPage.html(appName: appName,
                                                 settings: ReaderStore.settings(store: store),
                                                 suggestions: ReaderStore.suggestions(store: store)),
                               baseURL: nil)
    }

    // MARK: - Suggestions

    /// Fetches the sources, ranks them against what's been read, and hands the result to the
    /// start page. Everything here is best-effort: the fetch and ranking run off the main
    /// actor inside the task, and the page is already on screen and stays usable whatever
    /// happens. Main-actor isolated because it reads the page flags and hands off to the
    /// web view; every caller is already on the main thread.
    @MainActor
    private func loadSuggestions() {
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
    private func showSuggestions(_ items: [FeedItem]) {
        // The page may have been replaced while the feeds were in flight.
        guard isShowingStartPage else { return }
        let rows = items.map { ["title": $0.title, "url": $0.url, "source": $0.host] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else { return }
        webView.evaluateJavaScript(
            "window.readerSetSuggestions && window.readerSetSuggestions(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))")
    }

    // MARK: - Navigation policy

    // Web content and our own about:/data: pages load in the window; other schemes
    // (mailto:, msteams:, …) can't render here and go to their owning app.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !WebURL.loadsInApp(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // target=_blank / window.open: load in the same view rather than dropping it.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WebURL.loadsInApp(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    // MARK: - Reader auto-entry

    // A new navigation means whatever it lands on is a fresh page, not our reader
    // rendering — except the reader document's own load, marked by `pendingReaderRender`.
    @MainActor
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !pendingReaderRender { isShowingReader = false }
        // Our generated pages are real history entries, so back/forward can navigate AWAY
        // from one without going through any of the paths that reset these flags — left set,
        // they gate every message handler against the page actually on screen. But
        // `loadHTMLString` fires this too, and the load THIS app just started must not clear
        // the flag it just set. `PageState` owns that distinction (and is tested on it).
        pageState.navigationStarted()
        // Whatever is loading isn't the start page any more; a late result must not land on it.
        suggestionTask?.cancel()
    }

    // Every real page that finishes loading is offered to the reader; pages that don't
    // extract stay as they are. The reader document's own didFinish just marks it as
    // showing; a toggle back to the original suppresses one round.
    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if pendingReaderRender {
            pendingReaderRender = false
            isShowingReader = true
            return
        }
        if suppressReaderOnce {
            suppressReaderOnce = false
            return
        }
        // Our own start/settings load has landed; the page it set still stands.
        if let own = pageState.navigationFinished() {
            if own == .startPage { loadSuggestions() }
            return
        }
        // A recents row asked for this page explicitly — it beeps if extraction fails,
        // since the user asked for that article. Any finished load consumes the request.
        let requested = enterReaderForURL != nil && enterReaderForURL == webView.url
        enterReaderForURL = nil
        // The start page is up and interactive; the suggestions catch up when they can.
        if isShowingStartPage { loadSuggestions() }
        guard !isShowingReader, !isShowingFallback, !isShowingStartPage, !isShowingSettings
        else { return }
        // Anything that isn't a real web page here is a back/forward restore of one of our
        // own `loadHTMLString` documents (they carry no URL of their own — `about:blank`),
        // so ask the document what it is rather than trying to extract it.
        guard let url = webView.url, WebURL.isWebURL(url) else {
            remarkOwnPage()
            return
        }
        // A restored reader entry is handled by `enterReader`'s own sentinel; a restored
        // start or settings page has to be recognised from its generator marker.
        webView.evaluateJavaScript(Self.generatorScript) { @MainActor [weak self] result, _ in
            guard let self, self.webView.url == url else { return }
            let generator = (result as? String) ?? ""
            switch PageState.Page(generator: generator) {
            case .startPage:
                self.pageState.restored(generator: generator)
                self.loadSuggestions()
            case .settings:
                self.pageState.restored(generator: generator)
            default:
                // Including the reader, which `enterReader`'s own sentinel recognises.
                self.enterReader(from: url, manual: requested)
            }
        }
    }

    // MARK: - Load failures

    @MainActor
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    /// Replaces the view with the offline page for genuine top-level load failures,
    /// ignoring cancellations/policy interruptions that aren't real errors.
    private func showFallbackIfNeeded(for error: Error) {
        let nsError = error as NSError
        pageState.clear()
        // The load a recents row asked for never arrived; cleared before the ignorable
        // guard because cancelled loads are the likeliest way a row's navigation dies.
        enterReaderForURL = nil
        guard !OfflineFallback.isIgnorable(errorCode: nsError.code) else { return }

        failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        // A saved copy beats an error page — the article is what was asked for; ⌘R fetches
        // the live page again once the network is back. Not when the user just asked for the
        // ORIGINAL page (⇧⌘R): then the offline page is the honest answer, and its didFinish
        // consumes `suppressReaderOnce` exactly as before.
        if !suppressReaderOnce, let failed = failedURL,
           let cached = cache.article(for: URLCleaner.clean(failed)) {
            renderReader(cached, source: URLCleaner.clean(failed))
            return
        }
        let html = OfflineFallback.html(appName: appName, host: failedURL?.host,
                                        kind: OfflineFallback.classify(errorCode: nsError.code))
        isShowingFallback = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Messages from our pages

    // Each message is honored only while its page is actually showing — the handlers are
    // controller-wide, so a live site's JS could otherwise post to them.
    //
    // WebKit delivers these on the main thread, but the protocol requirement isn't annotated,
    // so the isolation has to be spelled out for the main-actor UI work the cases do.
    @MainActor
    func userContentController(_ userContentController: WKUserContentController,
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
            guard ownPage else { return }
            ReaderStore.setSettings(ReaderSettings.decode(message.body), store: store)
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
            // screen. Beep like the other explicit open paths.
            guard openIncoming(url) else {
                NSSound.beep()
                return
            }
            // The row promises the reader, so enter it once this load finishes. Keyed to
            // the URL `openIncoming` actually loads (it cleans first).
            enterReaderForURL = cleaned
        case "readerClear":
            guard ownPage else { return }
            ReaderStore.setHistory(ReaderHistory(), store: store)
            cache.prune(keeping: [])
        case "readerHide":
            // The reader page's floating affordance, where the Edit-menu item used to be:
            // learns the selection as a phrase, strips it from the article live, and hides
            // it in every article from now on. Beeps when the selection isn't usable — no
            // text, longer than a sentence, or already stored.
            guard ownPage, let text = message.body as? String else { return }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            guard phrases.add(text) else {
                NSSound.beep()
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
        case "readerHome":
            guard isShowingSettings else { return }
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
            // The start page's field, normalized like ⇧⌘O so bare "example.com/x" works.
            guard isShowingStartPage, let raw = message.body as? String else { return }
            guard let url = WebURL.clipboardURL(from: raw), openIncoming(url) else {
                NSSound.beep()
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
    private func remarkOwnPage() {
        webView.evaluateJavaScript(Self.generatorScript) { @MainActor [weak self] result, _ in
            guard let self else { return }
            let generator = (result as? String) ?? ""
            self.pageState.restored(generator: generator)
            if self.pageState.isShowingStartPage { self.loadSuggestions() }
        }
    }

    /// The `<meta name="generator">` content of the current document, or "" — how a restored
    /// page says which of ours it is.
    private static let generatorScript =
        "(document.querySelector('meta[name=\"generator\"]')||{}).content || ''"

    /// Tells the reader page which rating to draw for `url`. Used when a restored (back or
    /// forward) document's baked-in state may be out of date.
    private func pushRating(for url: URL) {
        let rating = ReaderStore.topics(store: store).rating(for: URLCleaner.clean(url).absoluteString)
        let value = rating.map { "'\($0.rawValue)'" } ?? "null"
        webView.evaluateJavaScript(
            "window.readerSetRating && window.readerSetRating(\(value), true)")
    }

    /// Stores a resolved source and tells the settings page to show its row.
    @MainActor
    private func addSource(_ source: FeedSource) {
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
    private func rejectSource(message: String = "No feed found at that address.") {
        guard isShowingSettings else { return }
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "window.readerSourceRejected && window.readerSourceRejected('\(escaped)')")
    }
}
