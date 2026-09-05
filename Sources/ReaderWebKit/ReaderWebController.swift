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
                webView.load(URLRequest(url: url))
            case let .show(html, baseURL):
                navigating = true
                loadOwnPage(html, baseURL: baseURL)
            case let .evaluate(script):
                guard !script.isEmpty else { continue }
                webView.evaluateJavaScript(script)
            case let .extract(url, script):
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
                    let next = await self.session.resolveSource(url)
                    await MainActor.run { _ = self.run(next) }
                }
            }
        }
        if settled, !navigating { loadingCover?.hide() }
        return navigating
    }

    /// Runs the extraction script and hands the answer back with the document's title. The
    /// title travels with it because a restored reader document's baked-in title belongs to
    /// whatever was rendered last, and reading it here costs one round trip instead of two.
    private func extract(url: URL, script: String) {
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            // Extraction takes a moment; if a navigation started meanwhile, `webView.url` is
            // already the new (provisional) URL and this result belongs to a page nobody
            // wants any more — rendering it would file page A's body under page B's key.
            guard self.webView.url == url else { return }
            self.webView.evaluateJavaScript("document.title") { title, _ in
                guard self.webView.url == url else { return }
                self.run(self.session.extractionResult(url: url, result: result as? String,
                                                       title: title as? String),
                         settled: true)
            }
        }
    }

    private func fetchSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let commands = await self.session.suggestions()
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self.run(commands) }
        }
    }

    /// Loads one of our own generated documents. The single place `loadHTMLString` is called
    /// (mirroring the GTK host's `loadHTML`), which is what gives the loading cover one place
    /// to come down: every own page — reader, start, settings, offline — settles here.
    private func loadOwnPage(_ html: String, baseURL: URL?) {
        loadingCover?.hide()
        coverSuppressedOnce = true
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
        webView.evaluateJavaScript(ReaderSession.generatorScript) { [weak self] result, _ in
            guard let self else { return }
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
