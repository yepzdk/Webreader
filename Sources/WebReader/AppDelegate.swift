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
    private var isShowingStartPage = false
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
        // Our generated pages post here: the offline page's Try Again, the reader's Aa and
        // recents popovers, and the start page's URL field.
        for name in ["readerRetry", "readerSettings", "readerOpen", "readerClear", "readerOpenURL"] {
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

    @objc private func reloadPage(_ sender: Any?) { webView.reload() }
    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func goForward(_ sender: Any?) { webView.goForward() }
    @objc private func goHome(_ sender: Any?) { showStartPage() }

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
            enterReader(manual: true)
        }
    }

    /// Runs the Readability extraction on the current page and, on success, loads the
    /// reader rendering as its OWN document (baseURL = the article, so relative image URLs
    /// resolve). A new document rather than an in-place DOM swap, because the article
    /// page's still-running JS must die with its page — hydrating sites were reverting
    /// in-place swaps within a second. Failure leaves the page untouched: a beep for a
    /// manual request, silence for the automatic path — never an error page.
    private func enterReader(manual: Bool) {
        webView.evaluateJavaScript(Reader.extractionScript) { [weak self] result, _ in
            guard let self else { return }
            guard let article = Reader.decode(result) else {
                if manual { NSSound.beep() }
                return
            }
            self.readerSourceURL = self.webView.url
            // Record before rendering so the article being opened is the panel's top row.
            // The cleaned URL, because opening a row routes through `openIncoming`, which
            // cleans — recording the raw one would make the replay look like a new article.
            var history = ReaderStore.history(store: self.store)
            if let source = self.readerSourceURL {
                history.record(title: article.title, url: URLCleaner.clean(source).absoluteString)
                ReaderStore.setHistory(history, store: self.store)
            }
            let html = ReaderPage.html(article: article,
                                       settings: ReaderStore.settings(store: self.store),
                                       history: history)
            self.pendingReaderRender = true
            self.webView.loadHTMLString(html, baseURL: self.readerSourceURL)
        }
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
            isShowingStartPage = false
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
        isShowingStartPage = true
        webView.loadHTMLString(StartPage.html(appName: appName,
                                              settings: ReaderStore.settings(store: store),
                                              history: ReaderStore.history(store: store)),
                               baseURL: nil)
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
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !pendingReaderRender { isShowingReader = false }
    }

    // Every real page that finishes loading is offered to the reader; pages that don't
    // extract stay as they are. The reader document's own didFinish just marks it as
    // showing; a toggle back to the original suppresses one round.
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
        // A recents row asked for this page explicitly — it beeps if extraction fails,
        // since the user asked for that article. Any finished load consumes the request.
        let requested = enterReaderForURL != nil && enterReaderForURL == webView.url
        enterReaderForURL = nil
        guard !isShowingReader, !isShowingFallback, !isShowingStartPage,
              let url = webView.url, WebURL.isWebURL(url) else { return }
        enterReader(manual: requested)
    }

    // MARK: - Load failures

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    /// Replaces the view with the offline page for genuine top-level load failures,
    /// ignoring cancellations/policy interruptions that aren't real errors.
    private func showFallbackIfNeeded(for error: Error) {
        let nsError = error as NSError
        isShowingStartPage = false
        // The load a recents row asked for never arrived; cleared before the ignorable
        // guard because cancelled loads are the likeliest way a row's navigation dies.
        enterReaderForURL = nil
        guard !OfflineFallback.isIgnorable(errorCode: nsError.code) else { return }

        failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        let html = OfflineFallback.html(appName: appName, host: failedURL?.host,
                                        kind: OfflineFallback.classify(errorCode: nsError.code))
        isShowingFallback = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Messages from our pages

    // Each message is honored only while its page is actually showing — the handlers are
    // controller-wide, so a live site's JS could otherwise post to them.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let ownPage = isShowingReader || pendingReaderRender || isShowingStartPage
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
            // A rejected URL must leave the reader state alone — the reader is still on
            // screen. Beep like the other explicit open paths.
            guard openIncoming(url) else {
                NSSound.beep()
                return
            }
            // The row promises the reader, so enter it once this load finishes. Keyed to
            // the URL `openIncoming` actually loads (it cleans first).
            enterReaderForURL = URLCleaner.clean(url)
        case "readerClear":
            guard ownPage else { return }
            ReaderStore.setHistory(ReaderHistory(), store: store)
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
}
