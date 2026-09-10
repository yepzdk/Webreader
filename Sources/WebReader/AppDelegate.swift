import Cocoa
import ReaderKit
import ReaderWebKit
import WebKit

/// The AppKit shell around `ReaderWebController`: one window, the main menu, the Mac's
/// answers to the handful of things WebKit cannot answer for itself (a beep, the clipboard,
/// `NSWorkspace`), and the two native surfaces — the loading cover and the sync sheet.
///
/// Everything about *reading* — the page state machine, extraction, the script messages —
/// lives in `ReaderWebKit` so the iOS shell (#6) runs the same code rather than a second
/// copy of it.
final class AppDelegate: NSObject, NSApplicationDelegate, ReaderHostServices {
    private var window: NSWindow!
    private var controller: ReaderWebController!
    private var progressLine: ProgressLine?
    private var loadingCover: LoadingCover!
    private let store: KeyValueStore = DefaultsStore()
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebReader"

    /// WKWebView's stock UA lacks the "Version/x Safari/x" suffix, which UA-sniffing sites
    /// read as an ancient or unknown browser ("this browser is no longer supported").
    private static let safariApplicationName = "Version/26.0 Safari/605.1.15"

    /// A URL received before the controller exists (cold launch via a link).
    private var pendingIncomingURL: URL?

    /// On-disk copies of the recent articles (see `ArticleCache`): recents rows open from
    /// here, and a failed load falls back to it.
    private let cache = ArticleCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dk.yepz.webreader")
            .appendingPathComponent("articles"))

    /// Sync (issue #7): the shared folder this Mac exchanges settings and recents through,
    /// and the sheet that points it at one.
    private var sync: ReaderSyncController!
    private var syncSheet: SyncSheet?

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

        controller = ReaderWebController(store: store, cache: cache, appName: appName,
                                         platform: .macOS,
                                         userAgentApplicationName: Self.safariApplicationName,
                                         services: self)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        if !window.setFrameUsingName("WebReaderMainWindow") { window.center() }
        window.setFrameAutosaveName("WebReaderMainWindow")

        let webView = controller.webView
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        // Page zoom is the Mac's alone: WKWebView has no counterpart on iOS, where the
        // viewport meta leaves pinch-zoom available instead.
        webView.pageZoom = ReaderStore.zoom(store: store)
        window.contentView!.addSubview(webView)
        loadingCover = LoadingCover(over: webView, in: window.contentView!)
        controller.loadingCover = loadingCover
        progressLine = ProgressLine(webView: webView, in: window.contentView!)

        sync = ReaderSyncController(store: store, platform: MacSyncPlatform()) { [weak self] result in
            self?.controller.applySync(result)
        }
        sync.onStatusChange = { [weak self] in
            self?.syncSheet?.refresh()
            self?.controller.syncStatusChanged()
        }
        controller.sync = sync

        // A real main menu is required for the standard editing shortcuts (⌘C/⌘V/⌘X/⌘A)
        // to reach the web content — without it, paste silently does nothing.
        NSApp.mainMenu = buildMainMenu()

        let pending = pendingIncomingURL
        pendingIncomingURL = nil
        controller.start(initialURL: pending)
        sync.start()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        sync?.applicationDidBecomeActive()
    }

    // MARK: - Host services

    /// The app said no. On a Mac that is the system beep — the only feedback these paths have.
    func reject() { NSSound.beep() }

    func openExternally(_ url: URL) { NSWorkspace.shared.open(url) }

    func bringToFront() { NSApp.activate(ignoringOtherApps: true) }

    func presentSyncSetup() { showSyncSheet(nil) }

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
        appMenu.addItem(withTitle: "Sync…", action: #selector(showSyncSheet(_:)), keyEquivalent: "")
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
        viewMenu.addItem(withTitle: "Show the Original Page",
                         action: #selector(toggleOriginal(_:)), keyEquivalent: "R")
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
            return WebURL.urlToCopy(currentURL: controller?.webView.url) != nil
        case #selector(goBack(_:)):
            return controller?.canGoBack ?? false
        case #selector(goForward(_:)):
            return controller?.webView.canGoForward ?? false
        case #selector(toggleReader(_:)):
            // Needs a real web page (the start page / offline page aren't articles).
            return controller?.canToggleReader ?? false
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

    @objc private func reloadPage(_ sender: Any?) { controller.reload() }
    @objc private func goBack(_ sender: Any?) { controller.back() }
    @objc private func goForward(_ sender: Any?) { controller.webView.goForward() }
    @objc private func goHome(_ sender: Any?) { controller.showStartPage() }
    @objc private func showSettings(_ sender: Any?) { controller.showSettingsPage() }
    @objc private func toggleReader(_ sender: Any?) { controller.toggleReader() }
    @objc private func toggleOriginal(_ sender: Any?) { controller.toggleOriginal() }

    @objc private func showSyncSheet(_ sender: Any?) {
        let sheet = syncSheet ?? SyncSheet(controller: sync)
        syncSheet = sheet
        sheet.present(in: window)
    }

    @objc private func openFromClipboard(_ sender: Any?) {
        guard let url = WebURL.clipboardURL(from: NSPasteboard.general.string(forType: .string)),
              controller.openIncoming(url) else {
            NSSound.beep()
            return
        }
    }

    @objc private func copyCurrentURL(_ sender: Any?) {
        guard let url = WebURL.urlToCopy(currentURL: controller.webView.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func zoomIn(_ sender: Any?) { applyZoom(controller.webView.pageZoom + ReaderStore.zoomStep) }
    @objc private func zoomOut(_ sender: Any?) { applyZoom(controller.webView.pageZoom - ReaderStore.zoomStep) }
    @objc private func actualSize(_ sender: Any?) { applyZoom(1.0) }

    private func applyZoom(_ raw: Double) {
        let clamped = ReaderStore.clampZoom(raw)
        controller.webView.pageZoom = clamped
        ReaderStore.setZoom(clamped, store: store)
    }

    /// Stock appearance and zoom; history is left alone. Whatever generated page is up is
    /// redrawn with the defaults — the reader by reloading its source, which auto-enters.
    @objc private func resetReaderAppearance(_ sender: Any?) {
        controller.webView.pageZoom = 1.0
        controller.resetAppearance()
    }

    // MARK: - Incoming URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-window model: navigate to the first acceptable URL, ignore the rest.
        for url in urls where accept(url) { return }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        accept(url)
    }

    /// Hands a URL to the controller, or stashes it when the app is still launching (a cold
    /// launch via a link arrives before `applicationDidFinishLaunching`).
    @discardableResult
    private func accept(_ url: URL) -> Bool {
        guard let controller else {
            let cleaned = URLCleaner.clean(url)
            guard WebURL.isWebURL(cleaned) else { return false }
            pendingIncomingURL = cleaned
            return true
        }
        return controller.openIncoming(url)
    }
}
