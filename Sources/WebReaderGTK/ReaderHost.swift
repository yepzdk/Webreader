import Foundation
import CWebKitGTK
import ReaderKit

/// The reader itself on Linux: which of our own documents is on screen, when to extract an
/// article, what the generated pages are allowed to ask for, and what happens when a load
/// fails. The GTK/GApplication orchestration around it is `Application`; the reader logic it
/// wires up is `ReaderKit`. This is the direct counterpart of the AppKit host's
/// `AppDelegate`, minus the window, the menu and the accelerators.
///
/// Two things differ from WKWebView and shape everything below.
///
/// WebKitGTK hands out **no navigation identity**: there is no `WKNavigation` to compare, and
/// `webkit_web_view_load_html` emits STARTED/COMMITTED/FINISHED with `get_uri()` equal to the
/// `base_uri` it was given — byte-identical to a real navigation to that URL. So the only
/// thing that tells our own render from a foreign one is the flag `PageState.willShow` sets
/// immediately before every `load_html`. That is the same distinction 0.10.0 got wrong on
/// macOS (see CLAUDE.md), which is why it lives in `PageState`, in the tested target.
///
/// And `MainActor` is **not** the GTK thread here: its Linux executor is `DispatchQueue.main`,
/// which nothing ever runs — `g_application_run` owns the process's main thread with a GLib
/// main loop. Everything in this file therefore runs on the GTK thread already, and the two
/// places that leave it for `async` work come home through `onGTKMainLoop`, never `MainActor`.
final class ReaderHost {
    /// The name the generated pages print. A constant, not a bundle lookup: there is no
    /// bundle on Linux. The *window* title is `Application`'s business — `onTitleChange("")`
    /// asks it for its own default rather than duplicating it here.
    private static let appName = "WebReader"

    /// The `<meta name="generator">` content of the current document, or "" — how a restored
    /// page says which of ours it is.
    private static let generatorScript =
        "(document.querySelector('meta[name=\"generator\"]')||{}).content || ''"

    /// The reader's own generator marker, taken from `PageState` so the string exists once.
    private static let readerGenerator = PageState.Page.reader.generator ?? ""

    /// Every name the generated pages post to. The host registers exactly these and gates
    /// each one on the page flags, so a live site's JS can't reach them.
    private static let messageNames = [
        "readerRetry", "readerSettings", "readerOpen", "readerClear", "readerOpenURL",
        "readerHide", "readerUnhide", "readerOpenSettings", "readerHome",
        "readerAddSource", "readerRemoveSource", "readerSetLanguages",
        "readerBlockHost", "readerUnblockHost", "readerTopicFeedback", "readerRate",
    ]

    // MARK: - Collaborators

    /// `WebKitWebView` is a derivable GObject type, so its instance struct is public and
    /// Swift imports the pointer as a typed one; `WebKitUserContentManager` is final and
    /// opaque, so it stays an `OpaquePointer`. Both arrive as `OpaquePointer` from
    /// `Application` precisely so neither unit has to know that.
    private let view: UnsafeMutablePointer<WebKitWebView>
    private let userContent: OpaquePointer
    private let store: KeyValueStore
    private let cache: ArticleCache
    /// Read per render, not once: `OmarchyTheme.current()` re-reads the theme's colours, which
    /// is how switching desktop theme reaches the next page we draw.
    private let palette: () -> ReaderPalette?

    /// Set by `Application` so the window title can follow the article. `""` means "no
    /// article" — the window falls back to its own default rather than to a copy of it here.
    var onTitleChange: ((String) -> Void)?

    // MARK: - Page state

    /// Which of our own generated documents is on screen (`ReaderKit.PageState`), and the
    /// gate on every script message handler. Never inferred from the current URL: a
    /// `load_html` document reports its base URI, which for the reader is the article's own
    /// URL and for the start page is `about:blank`.
    private var pageState = PageState()
    private var isShowingStartPage: Bool { pageState.isShowingStartPage }
    private var isShowingSettings: Bool { pageState.isShowingSettings }
    private var isShowingReader: Bool { pageState.page == .reader }
    private var isShowingFallback: Bool { pageState.page == .fallback }

    /// The URL whose load produced the offline page, so Try Again retries *that* navigation
    /// rather than going home.
    private var failedURL: URL?
    /// Set by `load-failed` and consumed by the FINISHED that WebKitGTK always emits right
    /// after it. The replacement page is rendered from there rather than from the failure
    /// handler because a `load_html` issued inside `load-failed` would have the page state it
    /// just set consumed by the *failed* load's own FINISHED, which arrives afterwards.
    private var pendingFailure: OfflineFallback.Kind?

    /// Reader state. `suppressReaderOnce`: set when toggling back to the original page so its
    /// load isn't immediately re-extracted. `enterReaderForURL`: the URL a recents row asked
    /// for — a URL rather than a bool so the request can't leak onto an unrelated page.
    /// `readerSourceURL`: what the current rendering was extracted from; the reader toggle
    /// loads it to get back to the original page.
    private var suppressReaderOnce = false
    private var enterReaderForURL: URL?
    private var readerSourceURL: URL?
    /// The title of the article currently rendered, so a like/dislike learns terms from the
    /// headline rather than from the URL. Set when the reader renders, and cleared when
    /// back/forward restores a reader document until that page's own title is read back —
    /// rating with a stale title would file one article's terms under another's URL.
    /// Only ever consulted while `isShowingReader`.
    private var readerArticleTitle: String?

    /// The suggestion sources' fetcher, and the in-flight ranking for the start page.
    /// Suggestions are strictly best-effort: the start page renders without them and the task
    /// is cancelled the moment the page goes away.
    private let feeds = FeedFetcher()
    private var suggestionTask: Task<Void, Never>?

    /// One box per script message name, kept alive here (see `MessageBinding`).
    private var messageBindings: [MessageBinding] = []

    init(webView: OpaquePointer, userContentManager: OpaquePointer,
         store: KeyValueStore, cache: ArticleCache,
         palette: @escaping () -> ReaderPalette?) {
        self.view = UnsafeMutablePointer<WebKitWebView>(webView)
        self.userContent = userContentManager
        self.store = store
        self.cache = cache
        self.palette = palette
    }

    // MARK: - Signals

    /// Connects the load lifecycle, the policy decision and every script message handler.
    ///
    /// The message handlers are connected *before* their names are registered, which is the
    /// order WebKit's own header asks for: the name is the signal detail, so registering
    /// first opens a window in which a message can arrive with nothing attached.
    func connectSignals() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        wr_connect_load_changed(view, Self.onLoadChanged, me)
        wr_connect_load_failed(view, Self.onLoadFailed, me)
        wr_connect_decide_policy(view, Self.onDecidePolicy, me)

        for name in Self.messageNames {
            let binding = MessageBinding(host: self, name: name)
            messageBindings.append(binding)
            wr_connect_script_message(userContent, name, Self.onScriptMessage,
                                      Unmanaged.passUnretained(binding).toOpaque())
            webkit_user_content_manager_register_script_message_handler(userContent, name, nil)
        }
    }

    /// `self` travels through every GObject callback's `user_data`, unretained: `Application`
    /// holds the host for as long as the window exists, so nothing here needs to own it.
    private static func host(_ data: UnsafeMutableRawPointer?) -> ReaderHost {
        Unmanaged<ReaderHost>.fromOpaque(data!).takeUnretainedValue()
    }

    private static let onLoadChanged: WRLoadChangedFunc = { _, event, data in
        ReaderHost.host(data).loadChanged(event)
    }

    private static let onLoadFailed: WRLoadFailedFunc = { _, _, uri, error, data in
        ReaderHost.host(data).loadFailed(uri: uri, error: error)
    }

    private static let onDecidePolicy: WRDecidePolicyFunc = { _, decision, type, data in
        ReaderHost.host(data).decidePolicy(decision, type)
    }

    private static let onScriptMessage: WRScriptMessageFunc = { _, value, data in
        let binding = Unmanaged<MessageBinding>.fromOpaque(data!).takeUnretainedValue()
        binding.host.handle(message: binding.name, payload: value)
    }

    /// One box per handler name. `script-message-received` is a *detailed* signal, but the
    /// detail never reaches the handler — so a capture-free `@convention(c)` callback cannot
    /// tell which of the sixteen names fired unless the name travels in `user_data` beside
    /// the host. `unowned` because the host owns the boxes.
    private final class MessageBinding {
        unowned let host: ReaderHost
        let name: String

        init(host: ReaderHost, name: String) {
            self.host = host
            self.name = name
        }
    }

    // MARK: - Entry points

    /// Routes an incoming URL: cleans it (tracking redirects unwrapped, tracking params
    /// stripped — so the app never contacts a tracking host, which may well be blocked),
    /// ignores non-web URLs, and loads the rest live. Recents are recorded when the article
    /// reaches the reader, not here: the list is what has been *read*.
    func openIncoming(_ url: URL) {
        route(url)
    }

    /// The reader toggle. Leaving it loads the page the rendering came from; entering it runs
    /// the extraction against whatever is on screen.
    func toggleReader() {
        if isShowingReader {
            // Back to the original page; its load must not immediately re-enter.
            suppressReaderOnce = true
            pageState.clear()
            if let source = readerSourceURL {
                webkit_web_view_load_uri(view, source.absoluteString)
            } else {
                webkit_web_view_reload(view)
            }
            return
        }
        // Needs a real web page: the start, settings and offline pages aren't articles.
        guard let url = currentURL, WebURL.isWebURL(url) else {
            beep()
            return
        }
        enterReader(from: url, manual: true)
    }

    /// The start page: URL field, recents, and the appearance controls — reading the same
    /// persisted settings as the reader page.
    func goHome() {
        failedURL = nil
        pendingFailure = nil
        onTitleChange?("")
        loadHTML(StartPage.html(appName: Self.appName,
                                settings: ReaderStore.settings(store: store),
                                history: ReaderStore.history(store: store),
                                hidden: ReaderStore.hiddenPhrases(store: store),
                                platform: .linux,
                                palette: palette()),
                 base: nil, as: .startPage)
    }

    /// The settings page: the suggestion sources and their language filter.
    func openSettings() {
        suggestionTask?.cancel()
        suggestionTask = nil
        failedURL = nil
        pendingFailure = nil
        onTitleChange?("")
        loadHTML(SettingsPage.html(appName: Self.appName,
                                   settings: ReaderStore.settings(store: store),
                                   suggestions: ReaderStore.suggestions(store: store),
                                   platform: .linux,
                                   palette: palette()),
                 base: nil, as: .settings)
    }

    /// Reload, per page.
    ///
    /// `webkit_web_view_reload` re-fetches the current URI as a real network load; it does not
    /// re-run `load_html`. For our own documents that URI is either the article (the reader,
    /// where re-fetching is exactly right — it re-extracts and refreshes the cached copy) or
    /// `about:blank` (the start, settings and offline pages, where re-fetching would blank the
    /// window). So those three are re-issued rather than reloaded.
    func reload() {
        if isShowingReader, let source = readerSourceURL {
            pageState.clear()
            webkit_web_view_load_uri(view, source.absoluteString)
        } else if isShowingStartPage {
            goHome()
        } else if isShowingSettings {
            openSettings()
        } else if isShowingFallback {
            if let failedURL { route(failedURL) } else { goHome() }
        } else {
            webkit_web_view_reload(view)
        }
    }

    /// The URL to put on the clipboard, or nil when there is nothing worth copying. The
    /// window has no address bar, so this is the only way the URL gets out.
    func urlToCopy() -> String? {
        guard !isShowingStartPage, !isShowingSettings, !isShowingFallback else { return nil }
        // In the reader, the URL that matters is the article's, not the rendered document's —
        // they happen to agree (the base URI), but the source is the one we actually know.
        if isShowingReader, let source = readerSourceURL {
            return WebURL.urlToCopy(currentURL: source)
        }
        return WebURL.urlToCopy(currentURL: currentURL)
    }

    // MARK: - Loading our own documents

    /// The single place `webkit_web_view_load_html` is called, so `PageState.willShow` cannot
    /// be forgotten before one. See the type's own note: that call is the only thing that
    /// distinguishes this load from a foreign navigation to the same URI.
    private func loadHTML(_ html: String, base: URL?, as page: PageState.Page) {
        pageState.willShow(page)
        // Spelled out rather than passing an optional String through: the implicit
        // String-to-`const char *` bridge is only defined for a non-optional argument.
        if let base {
            webkit_web_view_load_html(view, html, base.absoluteString)
        } else {
            webkit_web_view_load_html(view, html, nil)
        }
    }

    /// Cleans, filters and loads an incoming link. Returns whether it was accepted, so the
    /// explicit paths (a recents row, the start page's field) can say no.
    @discardableResult
    private func route(_ url: URL) -> Bool {
        let url = URLCleaner.clean(url)
        guard WebURL.isWebURL(url) else { return false }
        pageState.clear()
        failedURL = nil
        pendingFailure = nil
        webkit_web_view_load_uri(view, url.absoluteString)
        return true
    }

    // MARK: - Reader

    /// Runs the Readability extraction on the page at `url` (the one that just finished
    /// loading) and, on success, caches the article and loads the reader rendering as its OWN
    /// document (base URI = the article, so relative image URLs resolve). A new document
    /// rather than an in-place DOM swap, because the article page's still-running JS must die
    /// with its page — hydrating sites were reverting in-place swaps within a second. Failure
    /// leaves the page untouched: a beep for a manual request, silence for the automatic
    /// path — never an error page.
    private func enterReader(from url: URL, manual: Bool) {
        let hidden = ReaderStore.hiddenPhrases(store: store)
        evaluateJavaScript(Reader.extractionScript(hiding: hidden)) { [weak self] result in
            guard let self else { return }
            // Back/forward landed on one of our own reader documents: it IS the reader, so
            // just say so. Nothing to extract, record, or cache.
            if result == Reader.ownPageSentinel {
                self.pageState.restored(generator: Self.readerGenerator)
                self.readerSourceURL = url
                // We arrived here through back/forward rather than `renderReader`, so the
                // title from the last rendering belongs to a different article. Drop it
                // immediately — a rating clicked before the lookup returns must learn nothing
                // rather than the previous headline's terms — then fill it in for THIS page
                // only, since a newer navigation may land while the lookup is in flight.
                self.readerArticleTitle = nil
                self.evaluateJavaScript("document.title") { title in
                    guard self.readerSourceURL == url else { return }
                    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.readerArticleTitle = trimmed
                    self.onTitleChange?(trimmed ?? "")
                }
                // The restored document still shows the rating baked in when it was first
                // rendered; it may have changed since.
                self.pushRating(for: url)
                return
            }
            // Extraction takes a moment; if a navigation started meanwhile, the view's URI is
            // already the new one and this result belongs to a page nobody wants any more —
            // rendering it would file page A's body under page B's key.
            guard self.currentURL == url else { return }
            guard let article = Reader.decode(result) else {
                if manual { self.beep() }
                return
            }
            // Only a live extraction has something new to write; cache hits re-render as-is.
            self.cache.store(article, for: URLCleaner.clean(url))
            self.renderReader(article, source: url)
        }
    }

    /// Shows `article` as the reader document and records it in recents. `source` is the
    /// article page (the base URI, so relative images resolve). The single funnel for live
    /// extractions and cache hits, so page state is reset here and nowhere else; the cache is
    /// pruned here too, because recents — which it mirrors — change here.
    private func renderReader(_ article: Article, source: URL) {
        failedURL = nil
        pendingFailure = nil
        readerSourceURL = source
        readerArticleTitle = article.title
        // Record before rendering so the article being opened is the panel's top row. The
        // cleaned URL, because opening a row routes through `openIncoming`, which cleans —
        // recording the raw one would make the replay look like a new article.
        var history = ReaderStore.history(store: store)
        let key = URLCleaner.clean(source).absoluteString
        history.record(title: article.title, url: key)
        ReaderStore.setHistory(history, store: store)
        cache.prune(keeping: history.entries.map(\.url))
        let html = ReaderPage.html(article: article,
                                   settings: ReaderStore.settings(store: store),
                                   history: history,
                                   hidden: ReaderStore.hiddenPhrases(store: store),
                                   rating: ReaderStore.topics(store: store).rating(for: key),
                                   platform: .linux,
                                   palette: palette())
        onTitleChange?(article.title)
        loadHTML(html, base: source, as: .reader)
    }

    /// Tells the reader page which rating to draw for `url`. Used when a restored (back or
    /// forward) document's baked-in state may be out of date.
    private func pushRating(for url: URL) {
        let rating = ReaderStore.topics(store: store)
            .rating(for: URLCleaner.clean(url).absoluteString)
        let value = rating.map { "'\($0.rawValue)'" } ?? "null"
        evaluateJavaScript("window.readerSetRating && window.readerSetRating(\(value), true)")
    }

    // MARK: - Load lifecycle

    private func loadChanged(_ event: WebKitLoadEvent) {
        if event == WEBKIT_LOAD_STARTED {
            navigationStarted()
        } else if event == WEBKIT_LOAD_FINISHED {
            navigationFinished()
        }
    }

    /// A navigation started — `didStartProvisionalNavigation`'s equivalent. Our generated
    /// pages are real back/forward entries, so navigating away from one without going through
    /// any of the paths that reset the flags would otherwise leave them set, gating every
    /// message handler against the page actually on screen. But `load_html` fires this too,
    /// and the load this app just started must not clear the flag it just set: `PageState`
    /// owns that distinction, and is tested on it.
    private func navigationStarted() {
        pageState.navigationStarted()
        // Whatever is loading isn't the start page any more; a late result must not land on it.
        suggestionTask?.cancel()
        suggestionTask = nil
    }

    /// A load finished — `didFinish`'s equivalent. Every real page that lands here is offered
    /// to the reader; pages that don't extract stay as they are.
    private func navigationFinished() {
        // A failure's own FINISHED. `load-failed` deliberately renders nothing itself.
        if let kind = pendingFailure {
            pendingFailure = nil
            showFallback(kind)
            return
        }
        // Our own reader document has landed; it IS the reader, so there is nothing to do but
        // consume the pending state.
        if pageState.isPending, pageState.page == .reader {
            pageState.navigationFinished()
            return
        }
        // A toggle back to the original page suppresses one round of auto-entry. Consumed
        // before the general own-page handling because the retry may itself have failed, in
        // which case what landed is the offline page and its pending state is consumed here.
        if suppressReaderOnce {
            suppressReaderOnce = false
            pageState.navigationFinished()
            return
        }
        // Our own start/settings/offline load has landed; the page it set still stands.
        if let own = pageState.navigationFinished() {
            if own == .startPage { loadSuggestions() }
            return
        }
        // A recents row asked for this page explicitly — it beeps if extraction fails, since
        // the user asked for that article. Any finished load consumes the request.
        let requested = enterReaderForURL != nil && enterReaderForURL == currentURL
        enterReaderForURL = nil
        // The start page is up and interactive; the suggestions catch up when they can.
        if isShowingStartPage { loadSuggestions() }
        guard !isShowingReader, !isShowingFallback, !isShowingStartPage, !isShowingSettings
        else { return }
        // Anything that isn't a real web page here is a back/forward restore of one of our
        // own `load_html` documents whose base URI was nil (`about:blank`), so ask the
        // document what it is rather than trying to extract it.
        guard let url = currentURL, WebURL.isWebURL(url) else {
            remarkOwnPage()
            return
        }
        // A restored reader entry is handled by `enterReader`'s own sentinel; a restored start
        // or settings page has to be recognised from its generator marker.
        evaluateJavaScript(Self.generatorScript) { [weak self] result in
            guard let self, self.currentURL == url else { return }
            let generator = result ?? ""
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

    /// Reads the generator marker of a restored `load_html` document (back/forward onto the
    /// start or settings page) and re-establishes its flag. Without this the page is on screen
    /// with every one of its message handlers gated shut.
    private func remarkOwnPage() {
        evaluateJavaScript(Self.generatorScript) { [weak self] result in
            guard let self else { return }
            self.pageState.restored(generator: result ?? "")
            if self.pageState.isShowingStartPage { self.loadSuggestions() }
        }
    }

    // MARK: - Navigation policy

    /// Web content and our own about:/data: pages load in the window; other schemes (mailto:,
    /// msteams:, …) can't render here and go to their owning app. A `target=_blank` or
    /// `window.open` is loaded in this same view — the app is one window.
    ///
    /// Returning TRUE stops WebKit's default handler, which would otherwise also decide.
    private func decidePolicy(_ decision: UnsafeMutablePointer<WebKitPolicyDecision>?,
                              _ type: WebKitPolicyDecisionType) -> gboolean {
        guard let decision else { return 0 }
        guard type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
                || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION else { return 0 }
        let navigation = wr_nav_decision(UnsafeMutableRawPointer(decision))
        guard let action = webkit_navigation_policy_decision_get_navigation_action(navigation),
              let request = webkit_navigation_action_get_request(action),
              let uri = webkit_uri_request_get_uri(request),
              let url = URL(string: String(cString: uri)) else {
            webkit_policy_decision_use(decision)
            return 1
        }
        if type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION {
            // The port of the AppKit host's `createWebViewWith`: a new window is a load
            // request the app itself is about to make, so it is cleaned like any other.
            if WebURL.isWebURL(url) {
                route(url)
            } else if WebURL.loadsInApp(url) {
                webkit_web_view_load_uri(view, url.absoluteString)
            } else {
                openInDesktop(url)
            }
            webkit_policy_decision_ignore(decision)
            return 1
        }
        // A plain navigation is NOT cleaned or re-issued here: `decide-policy` fires for
        // subframes too, and cancelling one to re-load the main view would let an iframe
        // hijack the page. Cleaning belongs on the paths where the app itself starts a load.
        guard WebURL.loadsInApp(url) else {
            openInDesktop(url)
            webkit_policy_decision_ignore(decision)
            return 1
        }
        webkit_policy_decision_use(decision)
        return 1
    }

    /// Hands a URL this window cannot render to its owning application — the GIO equivalent of
    /// `NSWorkspace.open`.
    private func openInDesktop(_ url: URL) {
        g_app_info_launch_default_for_uri(url.absoluteString, nil, nil)
    }

    // MARK: - Load failures

    /// Returns TRUE unconditionally, which is what suppresses WebKit's stock error page —
    /// including for the cancellations and policy interruptions that aren't real failures,
    /// where the honest result is to leave the page that is already on screen alone.
    ///
    /// The replacement page is not rendered from here; see `pendingFailure`.
    private func loadFailed(uri: UnsafePointer<CChar>?,
                            error: UnsafeMutablePointer<GError>?) -> gboolean {
        // The load a recents row asked for never arrived; cleared before the ignorable guard
        // because a cancelled load is the likeliest way a row's navigation dies.
        enterReaderForURL = nil
        let code = Self.urlErrorCode(for: error)
        // An ignorable "failure" is a navigation the app itself refused — a mailto: link in
        // an article, a target=_blank we re-issued — and the page on screen is untouched, so
        // its page state must be untouched too. Clearing it here would leave the reader
        // visible with its own Aa, recents and rating handlers gated shut. (The AppKit host
        // gets away with clearing unconditionally only because its `isShowingReader` is a
        // separate bool that `PageState.clear()` doesn't reach.)
        guard !OfflineFallback.isIgnorable(errorCode: code) else { return 1 }
        pageState.clear()
        failedURL = uri.flatMap { URL(string: String(cString: $0)) }
        pendingFailure = OfflineFallback.classify(errorCode: code)
        return 1
    }

    private func showFallback(_ kind: OfflineFallback.Kind) {
        // A saved copy beats an error page — the article is what was asked for, and Reload
        // fetches the live page again once the network is back. Not when the user just asked
        // for the ORIGINAL page (the reader toggle): then the offline page is the honest
        // answer, and its FINISHED consumes `suppressReaderOnce` exactly as before.
        if !suppressReaderOnce, let failed = failedURL {
            let cleaned = URLCleaner.clean(failed)
            if let cached = cache.article(for: cleaned) {
                renderReader(cached, source: cleaned)
                return
            }
        }
        onTitleChange?("")
        loadHTML(OfflineFallback.html(appName: Self.appName, host: failedURL?.host, kind: kind,
                                      platform: .linux, palette: palette()),
                 base: nil, as: .fallback)
    }

    /// Translates a WebKitGTK load failure into the `NSURLError` raw value `OfflineFallback`
    /// classifies, so the classification — and the list of failures that are not failures —
    /// stays in the one place the tests cover instead of gaining a second Linux-shaped copy.
    ///
    /// WebKit's own network domain is coarse: almost every transport problem is
    /// `WEBKIT_NETWORK_ERROR_TRANSPORT`, with no distinct DNS or timeout code. So "you're
    /// offline" is answered by asking GLib whether there is a network at all, which is the
    /// distinction `NSURLErrorNotConnectedToInternet` draws on macOS; anything else with a
    /// live network reads as "can't reach the site".
    private static func urlErrorCode(for error: UnsafeMutablePointer<GError>?) -> Int {
        guard let error else { return 0 }
        let domain = error.pointee.domain
        let code = error.pointee.code
        if domain == webkit_policy_error_quark() {
            // A policy decision we made ourselves, not a broken site.
            let interrupted = WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE
            return code == gint(interrupted.rawValue) ? 102 : 0
        }
        if domain == webkit_network_error_quark(),
           code == gint(WEBKIT_NETWORK_ERROR_CANCELLED.rawValue) {
            return -999
        }
        if domain == g_io_error_quark() {
            switch code {
            case gint(G_IO_ERROR_CANCELLED.rawValue): return -999
            case gint(G_IO_ERROR_TIMED_OUT.rawValue): return -1001
            case gint(G_IO_ERROR_HOST_NOT_FOUND.rawValue),
                 gint(G_IO_ERROR_HOST_UNREACHABLE.rawValue): return -1003
            case gint(G_IO_ERROR_NETWORK_UNREACHABLE.rawValue): return -1009
            default: break
            }
        }
        if domain == g_resolver_error_quark(),
           code == gint(G_RESOLVER_ERROR_NOT_FOUND.rawValue) {
            return -1003
        }
        return networkAvailable() ? -1003 : -1009
    }

    private static func networkAvailable() -> Bool {
        guard let monitor = g_network_monitor_get_default() else { return true }
        return g_network_monitor_get_network_available(monitor) != 0
    }

    // MARK: - Messages from our pages

    /// Each message is honored only while its page is actually showing. The handlers are
    /// host-wide, so a live site's JS could otherwise post to them.
    private func handle(message name: String, payload: OpaquePointer?) {
        let ownPage = pageState.isOwnPage
        switch name {
        case "readerRetry":
            guard isShowingFallback else { return }
            if let failedURL {
                route(failedURL)
            } else {
                goHome()
            }

        case "readerSettings":
            // Guarded rather than tolerant: a payload we couldn't read must leave the stored
            // settings alone, not overwrite them with defaults.
            guard ownPage, let json = messageJSON(payload) else { return }
            ReaderStore.setSettings(ReaderSettings.fromJSON(json), store: store)

        case "readerOpen":
            guard ownPage, let raw = messageString(payload), let url = URL(string: raw)
            else { return }
            // A saved copy opens straight from disk: no load, no network. Only recents rows
            // take this shortcut — an incoming link is "read this now" and always loads live.
            let cleaned = URLCleaner.clean(url)
            if let cached = cache.article(for: cleaned) {
                renderReader(cached, source: cleaned)
                return
            }
            // A rejected URL must leave the reader state alone — the reader is still on
            // screen. Beep like the other explicit open paths.
            guard route(url) else {
                beep()
                return
            }
            // The row promises the reader, so enter it once this load finishes. Keyed to the
            // URL `route` actually loads (it cleans first).
            enterReaderForURL = cleaned

        case "readerClear":
            guard ownPage else { return }
            ReaderStore.setHistory(ReaderHistory(), store: store)
            cache.prune(keeping: [])

        case "readerHide":
            // The reader page's floating affordance: learns the selection as a phrase, strips
            // it from the article live, and hides it in every article from now on. Beeps when
            // the selection isn't usable — no text, longer than a sentence, or already stored.
            guard ownPage, let text = messageString(payload) else { return }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            guard phrases.add(text) else {
                beep()
                return
            }
            ReaderStore.setHiddenPhrases(phrases, store: store)
            evaluateJavaScript("window.readerSetHidden(\(phrases.scriptLiteral))")

        case "readerUnhide":
            guard ownPage, let phrase = messageString(payload) else { return }
            var phrases = ReaderStore.hiddenPhrases(store: store)
            phrases.remove(phrase)
            ReaderStore.setHiddenPhrases(phrases, store: store)

        case "readerOpenSettings":
            guard isShowingStartPage else { return }
            openSettings()

        case "readerHome":
            guard isShowingSettings else { return }
            goHome()

        case "readerAddSource":
            // The page has already disabled its button; it waits for one of the two callbacks.
            guard isShowingSettings, let raw = messageString(payload),
                  let url = WebURL.clipboardURL(from: raw) else {
                rejectSource()
                return
            }
            let feeds = feeds
            Task { [weak self] in
                guard let source = try? await feeds.resolve(url) else {
                    onGTKMainLoop { self?.rejectSource() }
                    return
                }
                onGTKMainLoop { self?.addSource(source) }
            }

        case "readerRemoveSource":
            guard isShowingSettings, let url = messageString(payload) else { return }
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
            guard isShowingSettings, let json = messageJSON(payload),
                  let codes = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
            else { return }
            var settings = ReaderStore.suggestions(store: store)
            // Everything ticked is the same as no filter — and stays right when a source
            // introducing a new language is added later. Nothing ticked means the same: an
            // empty set makes `rank` reject every item that declares a language, which would
            // silence suggestions entirely (see the `readerRemoveSource` case).
            let chosen = Set(codes)
            settings.languages = chosen.isEmpty || chosen == Set(settings.availableLanguages)
                ? nil : chosen
            ReaderStore.setSuggestions(settings, store: store)

        case "readerBlockHost":
            guard isShowingStartPage, let host = messageString(payload) else { return }
            var settings = ReaderStore.suggestions(store: store)
            settings.block(host: host)
            ReaderStore.setSuggestions(settings, store: store)
            // Refill the slot the blocked row left behind. The fetcher's TTL cache means this
            // re-ranks what's already in memory rather than hitting the network again.
            loadSuggestions()

        case "readerUnblockHost":
            guard isShowingSettings, let host = messageString(payload) else { return }
            var settings = ReaderStore.suggestions(store: store)
            settings.unblock(host: host)
            ReaderStore.setSuggestions(settings, store: store)

        case "readerTopicFeedback":
            // Stored only — the list deliberately doesn't reshuffle under the cursor; the
            // page's toast is what tells the user it landed.
            guard isShowingStartPage, let json = messageJSON(payload),
                  let feedback = try? JSONDecoder().decode(TopicFeedback.self,
                                                           from: Data(json.utf8)),
                  !feedback.title.isEmpty else { return }
            var topics = ReaderStore.topics(store: store)
            switch feedback.direction {
            case "more": topics.prefer(feedback.title)
            case "less": topics.avoid(feedback.title)
            default: return
            }
            ReaderStore.setTopics(topics, store: store)

        case "readerRate":
            // The reader's like/dislike. Keyed by the cleaned URL — the same key recents and
            // the cache use, so reopening an article shows the opinion you left on it.
            guard isShowingReader, let direction = messageString(payload),
                  let rating = TopicPreferences.Rating(rawValue: direction),
                  let source = readerSourceURL else { return }
            // Terms come from the headline; without one there is nothing to learn.
            guard let title = readerArticleTitle, !title.isEmpty else { return }
            var topics = ReaderStore.topics(store: store)
            let now = topics.setRating(rating, title: title,
                                       url: URLCleaner.clean(source).absoluteString)
            ReaderStore.setTopics(topics, store: store)
            let value = now.map { "'\($0.rawValue)'" } ?? "null"
            evaluateJavaScript("window.readerSetRating && window.readerSetRating(\(value))")

        case "readerOpenURL":
            // The start page's field, normalized like the clipboard path so bare
            // "example.com/x" works.
            guard isShowingStartPage, let raw = messageString(payload) else { return }
            guard let url = WebURL.clipboardURL(from: raw), route(url) else {
                beep()
                evaluateJavaScript("window.readerURLRejected && window.readerURLRejected()")
                return
            }

        default:
            break
        }
    }

    /// The `readerTopicFeedback` payload. A type rather than a dictionary lookup because
    /// `jsc_value_to_json` hands the message over as JSON, and `JSONDecoder` then does the
    /// shape checking that `WKScriptMessage.body`'s `[String: Any]` needed by hand.
    private struct TopicFeedback: Decodable {
        let title: String
        let direction: String
    }

    // MARK: - Suggestions

    /// Fetches the sources, ranks them against what's been read, and hands the result to the
    /// start page. Everything here is best-effort: the fetch and ranking run off the GTK
    /// thread inside the task, and the page is already on screen and stays usable whatever
    /// happens.
    private func loadSuggestions() {
        suggestionTask?.cancel()
        let settings = ReaderStore.suggestions(store: store)
        // No sources is precisely when the page's "add a source" empty state should show, so
        // tell the page that rather than leaving the section hidden.
        guard !settings.sources.isEmpty else {
            suggestionTask = nil
            showSuggestions([])
            return
        }
        let history = ReaderStore.history(store: store)
        let topics = ReaderStore.topics(store: store)
        let cache = cache
        let feeds = feeds
        suggestionTask = Task { [weak self] in
            let items = await feeds.items(for: settings.sources)
            guard !Task.isCancelled else { return }
            // The profile is the recent articles' own text, straight from the cache. A row
            // whose body has fallen out of the cache (it's a cache directory, and history
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
            onGTKMainLoop { self?.showSuggestions(ranked) }
        }
    }

    private func showSuggestions(_ items: [FeedItem]) {
        // The page may have been replaced while the feeds were in flight.
        guard isShowingStartPage else { return }
        let rows = items.map { ["title": $0.title, "url": $0.url, "source": $0.host] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [])
        else { return }
        let literal = HTML.jsLiteral(String(decoding: data, as: UTF8.self))
        evaluateJavaScript(
            "window.readerSetSuggestions && window.readerSetSuggestions(\(literal))")
    }

    /// Stores a resolved source and tells the settings page to show its row.
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
            openSettings()
            return
        }
        // The key is omitted rather than sent as null when the feed declares no language: the
        // page tests `if (source.language)`, and a nil in a `[String: Any]` is not encodable.
        var row: [String: Any] = ["title": source.title, "url": source.url]
        if let language = source.language { row["language"] = language }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [])
        else { return }
        let literal = HTML.jsLiteral(String(decoding: data, as: UTF8.self))
        evaluateJavaScript("window.readerSourceAdded && window.readerSourceAdded(\(literal))")
    }

    /// Re-enables the settings page's add form with an inline message.
    private func rejectSource(message: String = "No feed found at that address.") {
        guard isShowingSettings else { return }
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        evaluateJavaScript(
            "window.readerSourceRejected && window.readerSourceRejected('\(escaped)')")
    }

    // MARK: - JavaScript

    /// The URI the view reports. For our own `load_html` documents that is the base URI we
    /// passed: the article for the reader, `about:blank` for the rest. Never used to decide
    /// *which* page is on screen — that's `pageState`.
    private var currentURL: URL? {
        guard let uri = webkit_web_view_get_uri(view) else { return nil }
        return URL(string: String(cString: uri))
    }

    /// Runs `script` in the page and hands `then` the string it evaluated to, or nil when the
    /// script returned null/undefined, threw, or produced something other than a string.
    ///
    /// Every script this host runs returns a string — the extraction script hands back
    /// `JSON.stringify`'d text, the others a marker or a title — so the result is read with
    /// `jsc_value_to_string`. `jsc_value_to_json` would wrap that text in a second layer of
    /// JSON quoting; it is the right tool for the object payloads arriving the other way,
    /// which is where `messageJSON` uses it.
    private func evaluateJavaScript(_ script: String, then: ((String?) -> Void)? = nil) {
        let box = JSEvaluation(view: view, then: then)
        webkit_web_view_evaluate_javascript(
            view, script, -1, nil, nil, nil, Self.onJSFinished,
            Unmanaged.passRetained(box).toOpaque())
    }

    /// The callback fires exactly once, so passRetained/takeRetained is the pairing that
    /// frees the box.
    private static let onJSFinished: GAsyncReadyCallback = { _, result, data in
        Unmanaged<JSEvaluation>.fromOpaque(data!).takeRetainedValue().finish(result)
    }

    /// One `evaluate_javascript` call's continuation.
    private final class JSEvaluation {
        private let view: UnsafeMutablePointer<WebKitWebView>
        private let then: ((String?) -> Void)?

        init(view: UnsafeMutablePointer<WebKitWebView>, then: ((String?) -> Void)?) {
            self.view = view
            self.then = then
        }

        /// Always calls `_finish`, even with no continuation: it is what releases the async
        /// result. The `JSCValue` it returns is a full ref, and the `char *` from
        /// `jsc_value_to_string` is ours — both are freed here.
        func finish(_ result: OpaquePointer?) {
            var error: UnsafeMutablePointer<GError>?
            let value = webkit_web_view_evaluate_javascript_finish(view, result, &error)
            defer {
                if let value { g_object_unref(UnsafeMutableRawPointer(value)) }
                if let error { g_error_free(error) }
            }
            guard let value, jsc_value_is_string(value) != 0,
                  let raw = jsc_value_to_string(value) else {
                then?(nil)
                return
            }
            let text = String(cString: raw)
            g_free(raw)
            // A JS-level exception doesn't fail the async operation; it surfaces on the
            // value's context, where it would poison the next evaluation if left standing.
            // The AppKit host discards script errors the same way — silently.
            if let context = jsc_value_get_context(value),
               jsc_context_get_exception(context) != nil {
                jsc_context_clear_exception(context)
                then?(nil)
                return
            }
            then?(text)
        }
    }

    /// A script message's payload as a string. The `JSCValue` a script message delivers is
    /// borrowed, so nothing here unrefs it; the `char *` is ours and is freed.
    private func messageString(_ value: OpaquePointer?) -> String? {
        guard let value, jsc_value_is_string(value) != 0, let raw = jsc_value_to_string(value)
        else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// A script message's payload re-encoded as JSON, for the handlers whose page posts an
    /// object or an array. Walking `JSCValue` properties by hand would amount to
    /// re-implementing a JSON encoder at the C boundary.
    private func messageJSON(_ value: OpaquePointer?) -> String? {
        guard let value, let raw = jsc_value_to_json(value, 0) else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    // MARK: - Desktop feedback

    /// The AppKit host beeps when an explicit request can't be honoured — a URL that won't
    /// parse, an article that won't extract. This is the GDK equivalent; where the compositor
    /// has no bell configured it is a no-op, which is the platform's answer and not ours to
    /// override.
    private func beep() {
        guard let display = gdk_display_get_default() else { return }
        gdk_display_beep(display)
    }
}

/// Hands `body` to the GTK main loop.
///
/// `MainActor` is deliberately unused in this file: on Linux its executor is
/// `DispatchQueue.main`, and nothing here ever runs that queue — `g_application_run` owns the
/// process's main thread with a GLib main loop, so `await MainActor.run { … }` would simply
/// never fire. `g_idle_add` is documented thread-safe and invokes the callback in the loop's
/// own thread, which is the thread every GTK, WebKit and page-state call must happen on.
private func onGTKMainLoop(_ body: @escaping () -> Void) {
    g_idle_add(mainLoopTrampoline, Unmanaged.passRetained(MainLoopWork(body)).toOpaque())
}

/// A typed constant rather than a closure literal at the call site, so the C compiler's
/// `GSourceFunc` signature — not Swift's inference — is what checks the handler.
private let mainLoopTrampoline: GSourceFunc = { data in
    Unmanaged<MainLoopWork>.fromOpaque(data!).takeRetainedValue().body()
    return 0 // G_SOURCE_REMOVE: one-shot.
}

private final class MainLoopWork {
    let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }
}
