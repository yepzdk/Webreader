import Foundation
import WebKit
import ReaderKit

/// The reader as a `WKWebView`: it receives links, loads them, and swaps articles for the
/// reader rendering.
///
/// What the reader *decides* is `ReaderKit.ReaderSession` — the page-state machine, the
/// extraction flow, the seventeen script messages — and this class runs the commands it
/// hands back. The split is what lets three hosts share one implementation: WebKit is an
/// Apple framework, so the AppKit and UIKit shells share this adapter, and Android's Kotlin
/// host runs the same session over JNI with an adapter of its own.
///
/// What is left here is genuinely WebKit's: configuration, the delegate callbacks, the one
/// funnel through which our own documents are loaded, and the loading cover that has to come
/// down when the screen settles.
public final class ReaderWebController: NSObject, WKNavigationDelegate, WKUIDelegate,
                                        WKScriptMessageHandler {
    /// The view the shell puts on screen. Own pages must be loaded through this class (see
    /// `loadOwnPage`) so the page state and the loading cover stay in step; navigating it
    /// directly to a site is fine, and is what `openIncoming` does.
    public let webView: WKWebView

    /// Everything the reader decides. Public so a shell can read what is on screen — the
    /// Mac's menu asks whether the reader toggle has anything to act on.
    public let session: ReaderSession

    private unowned let services: ReaderHostServices

    /// The plain "Loading" screen. Set by the shell once the view hierarchy exists, so it is
    /// a var rather than an init argument; a host without one still works.
    public var loadingCover: ReaderLoadingCover?

    /// Sync (issue #7), or nil on a host that has none yet — in which case the settings page
    /// leaves the section out, exactly as it does on Linux.
    public var sync: ReaderSyncBridge? {
        didSet {
            session.onLocalStateChanged = { [weak self] in self?.sync?.localStateChanged() }
            session.onStartPageShown = { [weak self] in self?.sync?.startPageShown() }
            // Read at render time, not cached: the summary is relative to now, so a settings
            // page opened an hour after the last cycle would otherwise still say "a few
            // seconds ago".
            session.syncStatusProvider = { [weak self] in
                (self?.sync?.folderDisplayPath, self?.sync?.summary ?? "")
            }
            // Seeds the settings page's Sync section before anything is on screen: without
            // it the first render would carry an empty summary and leave the section out.
            _ = session.syncStatus(folder: sync?.folderDisplayPath, summary: sync?.summary ?? "")
        }
    }

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

    /// Set by `loadOwnPage` and consumed by the next `didStartProvisionalNavigation`: one of
    /// our own documents is already the answer, so its load must not raise the cover again.
    /// A one-shot rather than a test over the page flags — the flags differ per own page (the
    /// offline page sets none of them), and enumerating them is how a page gets stuck behind
    /// "Loading".
    private var coverSuppressedOnce = false

    /// The in-flight feed ranking. Suggestions are strictly best-effort: the page renders
    /// without them and the task is cancelled the moment the page goes away.
    private var suggestionTask: Task<Void, Never>?

    /// The stall watch, and what it is watching. A load that commits and then goes silent
    /// produces no callback at all — no finish, no failure — so without this the app waits
    /// behind the cover for as long as it is open. Owned here rather than by the cover
    /// because the answer is a command sequence (the offline page), not a change of view.
    private var stallWatchdog: Timer?
    private var progressObserver: NSKeyValueObservation?
    /// What `.load` asked for. `webView.url` is nil for a provisional load that never
    /// committed, which is exactly the case being reported.
    private var loadingURL: URL?

    /// The reveal waiting for a paint, and which navigation it is waiting for.
    private var paintTimer: Timer?
    private var paintGeneration = 0

    /// Silence before a load is called over. The app's is `LoadProgress.stallPatience`;
    /// tests shorten it, since the point of the number is that it is longer than a test.
    var stallPatience: Double = LoadProgress.stallPatience

    /// `userAgentApplicationName` is the shell's, because the string is a claim about the
    /// system: WKWebView's stock UA lacks the "Version/x Safari/x" suffix, which UA-sniffing
    /// sites read as an ancient or unknown browser ("this browser is no longer supported").
    public init(store: KeyValueStore,
                cache: ArticleCache,
                appName: String,
                platform: Platform,
                userAgentApplicationName: String,
                services: ReaderHostServices) {
        session = ReaderSession(store: store, cache: cache, appName: appName, platform: platform)
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
        // Debug builds only, so Safari's Develop menu can inspect the running app. Every page
        // in this app is a generated Swift string, which means a layout question about a real
        // window ("is this rule applying?") otherwise has no answer short of rebuilding with a
        // guess in it. `Scripts/build-app.sh` builds *release* by default, so this is off in
        // the bundle you normally run.
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, *) { webView.isInspectable = true }
        #endif
    }

    deinit {
        for name in Self.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - Commands

    /// Runs what the session asked for.
    ///
    /// `settled` is the cover's rule, and the only piece of judgement in here: what is on
    /// screen has stopped changing unless a command started a new navigation, and a page
    /// that never comes out from behind "Loading" is the failure this prevents.
    @discardableResult
    private func run(_ commands: [ReaderCommand], settled: Bool = false) -> Bool {
        var navigating = false
        for command in commands {
            switch command {
            case let .load(url):
                navigating = true
                // Covered here rather than in `didStartProvisionalNavigation`: everything
                // between issuing a load and WebKit reporting it is a window with the old
                // page, or the first paint of the new one, uncovered.
                loadingCover?.show(theme: ReaderStore.settings(store: session.store).theme)
                loadingURL = url
                paintGeneration += 1
                watchForStall()
                webView.load(URLRequest(url: url))
            case let .show(html, baseURL):
                navigating = true
                loadOwnPage(html, baseURL: baseURL)
            case let .evaluate(script):
                guard !script.isEmpty else { continue }
                webView.evaluateJavaScript(script)
            case let .extract(url, script):
                // Extraction is the rest of this navigation, not the end of it: hiding the
                // cover here would show the raw site for as long as Readability takes, which
                // is the flash the cover exists to prevent (#24). `extract` settles instead.
                navigating = true
                extract(url: url, script: script)
            case .reject:
                services.reject()
            case let .openExternally(url):
                services.openExternally(url)
            case .presentSyncSetup:
                services.presentSyncSetup()
            case .fetchSuggestions:
                fetchSuggestions()
            case let .resolveSource(url):
                Task { [weak self] in
                    guard let self else { return }
                    // Only the lookup happens off the main actor; what it found is applied
                    // back on it, because that half touches the session's state.
                    let source = await self.session.resolveSource(url)
                    await MainActor.run { _ = self.run(self.session.sourceResolved(source)) }
                }
            }
        }
        if settled, !navigating {
            stopWatchingForStall()
            revealWhenPainted()
        }
        return navigating
    }

    /// Takes the cover down once the document now loaded has actually painted.
    ///
    /// `didFinish` is the document loaded, which is not the same as it being on screen: until
    /// the new one paints, the web view is still showing the page it replaces. Measured on
    /// Android as two frames of the site between the two, and WKWebView is composited the
    /// same way — the same defect, closed by the same rule.
    ///
    /// WebKit has no first-paint delegate callback, so the page is asked instead:
    /// `requestAnimationFrame` resolves after the frame that drew this document. On its own
    /// that is not enough — a web view with no frames renders none, so an offscreen view or
    /// a backgrounded app never answers, and the cover would be terminal. A short timer runs
    /// beside it and the first of the two wins: the paint, within a frame, whenever there is
    /// one to wait for.
    private func revealWhenPainted() {
        paintTimer?.invalidate()
        let generation = paintGeneration
        paintTimer = Timer.scheduledTimer(withTimeInterval: Self.paintPatience, repeats: false) {
            [weak self] _ in MainActor.assumeIsolated { self?.reveal(generation) }
        }
        let script = "await new Promise(resolve => requestAnimationFrame(resolve)); return true"
        webView.callAsyncJavaScript(script, in: nil, in: .page) { @MainActor [weak self] _ in
            self?.reveal(generation)
        }
    }

    /// Reveals, unless a navigation started after the reveal was asked for — that cover
    /// belongs to the new load, and a late answer about the old one must not take it down.
    private func reveal(_ generation: Int) {
        guard generation == paintGeneration else { return }
        paintTimer?.invalidate()
        paintTimer = nil
        loadingCover?.hide()
    }

    /// Long enough that a view which does render frames always wins the race, short enough
    /// that one which never will is not a wait anybody notices.
    private static let paintPatience: Double = 0.5

    // MARK: - A load that never lands

    /// Starts the silence over. Armed when a load is issued and re-armed on every scrap of
    /// progress, so a slow load that is still moving is never interrupted.
    private func watchForStall() {
        if progressObserver == nil {
            progressObserver = webView.observe(\.estimatedProgress, options: [.new]) {
                [weak self] _, _ in
                // The load moved, so it is not stuck.
                guard let self, self.stallWatchdog != nil else { return }
                self.watchForStall()
            }
        }
        stallWatchdog?.invalidate()
        stallWatchdog = Timer.scheduledTimer(withTimeInterval: stallPatience,
                                             repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.giveUpOnTheLoad() }
        }
    }

    /// For the paths that ended the load one way or another; the watch has nothing left to
    /// answer for.
    private func stopWatchingForStall() {
        stallWatchdog?.invalidate()
        stallWatchdog = nil
    }

    /// Nothing was ever going to end this load. Stops it and reports the timeout it is, so
    /// the session answers with the page that says so — an ending, rather than a cover with
    /// no way past it.
    private func giveUpOnTheLoad() {
        stopWatchingForStall()
        webView.stopLoading()
        let url = loadingURL ?? webView.url
        run(session.loadFailed(url: url, code: NSURLErrorTimedOut), settled: true)
    }

    /// Runs the extraction script and hands the answer back with the document's title. The
    /// title travels with it because a restored reader document's baked-in title belongs to
    /// whatever was rendered last, and reading it here costs one round trip instead of two.
    private func extract(url: URL, script: String) {
        // WebKit delivers this on the main thread, but its signature does not say so, and
        // the branches below push state into the page. Spelled out rather than left to
        // Swift 5's leniency, which downgrades it to a warning that Swift 6 will not.
        webView.evaluateJavaScript(script) { @MainActor [weak self] result, _ in
            guard let self else { return }
            // Extraction takes a moment; if a navigation started meanwhile, `webView.url` is
            // already the new (provisional) URL and this result belongs to a page nobody
            // wants any more — rendering it would file page A's body under page B's key.
            guard self.webView.url == url else { return }
            self.webView.evaluateJavaScript("document.title") { @MainActor title, _ in
                guard self.webView.url == url else { return }
                self.run(self.session.extractionResult(url: url, result: result as? String,
                                                       title: title as? String),
                         settled: true)
            }
        }
    }

    private func fetchSuggestions() {
        suggestionTask?.cancel()
        // Snapshotted here, on the main actor: the ranking runs while the session keeps being
        // driven, so what it reads has to be taken before it leaves.
        let request = session.suggestionRequest()
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.session.suggestions(for: request)
            guard !Task.isCancelled else { return }
            // The session decides whether the page these were ranked for is still up.
            await MainActor.run { _ = self.run(self.session.showSuggestions(items)) }
        }
    }

    /// Loads one of our own generated documents. The single place `loadHTMLString` is called
    /// (mirroring the GTK host's `loadHTML`), which is what gives the loading cover one place
    /// to come down: every own page — reader, start, settings, offline — settles here.
    ///
    /// The cover is deliberately left up. Our document is the answer but it is not on screen
    /// yet — `loadHTMLString` has to parse and paint first — and taking the cover down here
    /// showed a frame or two of the page about to be replaced, which is the flash the cover
    /// exists to prevent (#24). It comes down when this document's own load settles.
    private func loadOwnPage(_ html: String, baseURL: URL?) {
        coverSuppressedOnce = true
        paintGeneration += 1
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - Commands the shell issues

    /// First page. A URL means the app was launched by a link; otherwise — or if that link
    /// turns out not to be one the app can open — the start page.
    public func start(initialURL: URL?) {
        run(session.start(initialURL: initialURL))
    }

    /// Routes an incoming URL, cleaning it first. Returns whether it was accepted.
    @discardableResult
    public func openIncoming(_ url: URL) -> Bool {
        let opened = session.openIncoming(url)
        guard opened.accepted else { return false }
        run(opened.commands)
        // Only an incoming link brings the app forward: a recents row or the reader toggle
        // is someone already looking at the window.
        services.bringToFront()
        return true
    }


    /// Back, as the reader means it: the previous article, or the page it came from.
    ///
    /// The session is asked first because the web view's history also holds every article
    /// page that was extracted on the way, and going back through one of those re-extracts it
    /// and returns you to the article you were leaving (#42). When the session has nothing of
    /// its own — a site's own pages — the web view's history is exactly right, so it answers.
    public func back() {
        let commands = session.back()
        guard commands.isEmpty else {
            run(commands)
            return
        }
        // Only someone else's page defers to the web view. From one of ours there is nowhere
        // left to go, and its history still holds our own documents — going back into one puts
        // an article on screen that the reader already left.
        if session.backFallback == .webViewHistory { webView.goBack() }
    }

    /// Whether Back has anywhere to go, from either half of the answer.
    public var canGoBack: Bool {
        session.canGoBack || (session.backFallback == .webViewHistory && webView.canGoBack)
    }

    public func showStartPage() { run(session.home()) }
    public func showSettingsPage() { run(session.showSettingsPage()) }
    public func toggleReader() { run(session.toggleReader(currentURL: webView.url)) }
    public func resetAppearance() { run(session.resetAppearance()) }

    /// In the reader, reloading fetches the source page again — which re-extracts and
    /// refreshes the cached copy. Reloading the rendered document would change nothing, so
    /// with no source to go back to this is WebKit's own reload.
    public func reload() {
        let commands = session.reload()
        if commands.isEmpty { webView.reload() } else { run(commands) }
    }

    /// Whether the reader toggle has anything to act on: a real web page, since the start
    /// and offline pages aren't articles.
    public var canToggleReader: Bool {
        guard let url = webView.url else { return false }
        return WebURL.isWebURL(url)
    }


    // MARK: - Sync

    /// Applies what a sync cycle merged in. The session decides what the pages need told;
    /// this only runs it.
    public func applySync(_ result: SyncEngine.Result) {
        run(session.applySync(result))
    }

    /// Sync's state changed: a folder chosen, a cycle landed, an error.
    public func syncStatusChanged() {
        run(session.syncStatus(folder: sync?.folderDisplayPath, summary: sync?.summary ?? ""))
    }

    // MARK: - Navigation

    // Web content and our own about:/data: pages load in the window; other schemes (mailto:,
    // msteams:, …) can't render here and go to their owning app.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !WebURL.loadsInApp(url) {
            services.openExternally(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// The response arrived and is not a web page — a feed, a PDF, a zip.
    ///
    /// Without this, WebKit decides on its own: it cancels the navigation with
    /// `WebKitErrorFrameLoadInterruptedByPolicyChange` (102), which `isIgnorable` deliberately
    /// swallows because that code is also what our own policy cancellations raise. Nothing
    /// renders, so whatever the window was showing stays — with no chrome of ours on it and no
    /// way back. Pasting a feed address into "Open URL from Clipboard" landed exactly there.
    ///
    /// Cancelled and answered with our own page instead, which carries Home. The code is
    /// WebKit's own `WebKitErrorCannotShowMIMEType`; `OfflineFallback.classify` turns it into
    /// the one kind that offers no Try Again, since asking again cannot answer differently.
    @MainActor
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        run(session.loadFailed(url: navigationResponse.response.url, code: 100), settled: true)
    }

    // target=_blank / window.open: load in the same view rather than dropping it.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WebURL.loadsInApp(url) {
                webView.load(URLRequest(url: url))
            } else {
                services.openExternally(url)
            }
        }
        return nil
    }

    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session.navigationStarted()
        // Someone else's page is on its way: cover it rather than let the site paint itself
        // only to be replaced by the reader a moment later (#24).
        if coverSuppressedOnce {
            coverSuppressedOnce = false
        } else {
            loadingCover?.show(theme: ReaderStore.settings(store: session.store).theme)
        }
        // Whatever is loading isn't the start page any more; a late result must not land on it.
        suggestionTask?.cancel()
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The generator marker is read for every finished load, including our own. It is how
        // a back/forward restore of a `loadHTMLString` document says which page it is — those
        // carry no URL of their own — and asking unconditionally keeps one path instead of a
        // fast lane that has to know which finishes can skip it.
        let url = webView.url
        webView.evaluateJavaScript(ReaderSession.generatorScript) { @MainActor [weak self] result, _ in
            guard let self else { return }
            // A navigation that started inside this round trip owns the page now, and it has
            // already told the session so. Committing this finish over it would mark a live
            // site as one of our own documents, with every message handler open to it.
            guard self.webView.url == url else { return }
            self.run(self.session.navigationFinished(url: url,
                                                     generator: (result as? String) ?? ""),
                     settled: true)
        }
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        fail(error)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        run(session.loadFailed(url: failed, code: nsError.code), settled: true)
    }

    // MARK: - Messages from our pages

    // WebKit delivers these on the main thread, but the protocol requirement isn't annotated,
    // so the isolation has to be spelled out for the main-actor work the commands do.
    @MainActor
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard let body = Self.body(of: message) else { return }
        run(session.message(message.name, body: body))
    }

    /// WebKit bridges a posted value to `String`, `[String]` or `[String: Any]` before it
    /// arrives. Narrowing it here rather than passing `Any` into ReaderKit is what lets the
    /// session be `Sendable` and lets a host that receives JSON text — WebKitGTK, Android —
    /// arrive at exactly the same three shapes.
    private static func body(of message: WKScriptMessage) -> ReaderSession.MessageBody? {
        if let text = message.body as? String { return .text(text) }
        if let list = message.body as? [String] { return .list(list) }
        if let fields = message.body as? [String: Any] {
            return .object(fields.compactMapValues { value in
                if let text = value as? String { return .text(text) }
                if let number = value as? Int { return .number(number) }
                return nil
            })
        }
        return nil
    }
}
