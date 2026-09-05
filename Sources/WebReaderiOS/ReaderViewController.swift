import UIKit
import UniformTypeIdentifiers
import WebKit
import ReaderKit
import ReaderWebKit

/// The whole app, as one full-screen web view.
///
/// The iOS counterpart of the Mac's `AppDelegate`: it owns the store, the article cache and
/// sync, answers the four questions `ReaderWebController` cannot answer for itself, and puts
/// the loading cover and the progress hairline over the web view in that order. Everything
/// about *reading* is in `ReaderWebKit`, shared byte-for-byte with the Mac.
///
/// There is no menu bar and no toolbar, which is not a gap: `Platform.iOS` already tells the
/// generated pages there are no keyboard commands to advertise, and the page chrome carries
/// Home, Settings, Aa and recents itself. What the Mac's menu has and this does not is page
/// zoom — `WKWebView` has no `pageZoom` on iOS, and the pages leave pinch-zoom available
/// instead.
final class ReaderViewController: UIViewController, ReaderHostServices,
                                  UIDocumentPickerDelegate {
    private let store: KeyValueStore = DefaultsStore(defaults: AppGroup.defaults)
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WebReader"

    /// WKWebView's stock UA lacks the "Version/x Safari/x" suffix, which UA-sniffing sites
    /// read as an ancient or unknown browser. The Mac claims Safari on macOS; here it has to
    /// claim Safari on iOS, or a site that serves a desktop layout to anything unrecognised
    /// undoes the whole point of the touch work.
    private static let safariApplicationName = "Version/26.0 Mobile/15E148 Safari/604.1"

    /// On-disk copies of the recent articles. The app's own Caches rather than the App
    /// Group's: only the app renders articles, and Caches is the right place for something
    /// the system may reclaim.
    private let cache = ArticleCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("articles"))

    private var controller: ReaderWebController!
    private var loadingCover: LoadingCover!
    private var progressLine: ProgressLine?
    private var sync: ReaderSyncController!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        controller = ReaderWebController(store: store, cache: cache, appName: appName,
                                         platform: .iOS,
                                         userAgentApplicationName: Self.safariApplicationName,
                                         services: self)

        let webView = controller.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Pinned to the edges, not the safe area, and with UIKit's own inset adjustment off:
        // every generated page sets `viewport-fit=cover` and places its fixed chrome with
        // `env(safe-area-inset-*)`, so letting UIKit inset the scroll view as well would
        // count the notch and the home indicator twice.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Z-order, bottom to top: web view, loading cover, progress hairline. The hairline
        // has to stay visible over the cover — it is the only thing on screen that says the
        // load is still moving.
        loadingCover = LoadingCover(over: webView, in: view)
        controller.loadingCover = loadingCover
        progressLine = ProgressLine(webView: webView, in: view)

        sync = ReaderSyncController(store: store, platform: IOSSyncPlatform()) { [weak self] result in
            self?.controller.applySync(result)
        }
        sync.onStatusChange = { [weak self] in self?.controller.syncStatusChanged() }
        controller.sync = sync
    }

    // MARK: - Lifecycle

    /// First page, and the link that launched the app if there was one.
    func start(with url: URL?) {
        loadViewIfNeeded()
        controller.start(initialURL: url.flatMap(incoming))
        sync.start()
    }

    func applicationDidBecomeActive() {
        // A link the share extension left behind while the app was closed or in the
        // background. Taken before the sync trigger so the reader is already on its way.
        if let shared = takePendingOpen() {
            controller.openIncoming(shared)
        }
        sync.applicationDidBecomeActive()
    }

    /// A URL the system handed the scene: either a link to read, or `webreader://open`,
    /// which is the share extension asking us to look in the shared store.
    func open(_ url: URL) {
        guard let target = incoming(url) else { return }
        controller.openIncoming(target)
    }

    /// Resolves what the system delivered into the link to read.
    ///
    /// `webreader://open?url=…` carries the link inline, which is what Shortcuts can build.
    /// A bare `webreader://open` means the link is in the shared store — the share
    /// extension's route, because an extension cannot hand a value to an app any other way
    /// that survives the app being closed.
    private func incoming(_ url: URL) -> URL? {
        guard url.scheme == "webreader" else { return url }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let inline = components?.queryItems?.first { $0.name == "url" }?.value
        guard let inline, !inline.isEmpty else { return takePendingOpen() }
        return WebURL.clipboardURL(from: inline)
    }

    /// Reads and clears the link the share extension left. Cleared on read so a link is
    /// opened once: the app is activated again every time it comes forward, and reopening
    /// yesterday's article each time would be worse than useless.
    private func takePendingOpen() -> URL? {
        let defaults = AppGroup.defaults
        guard let raw = defaults.string(forKey: AppGroup.pendingOpenKey) else { return nil }
        defaults.removeObject(forKey: AppGroup.pendingOpenKey)
        return WebURL.clipboardURL(from: raw)
    }

    // MARK: - Host services

    /// The app said no. There is no beep on a phone, and a silent refusal reads as a bug, so
    /// it is the error haptic — the one signal that works with the screen unlooked at.
    func reject() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    /// Nothing to do: on iOS the system decides what is in front, and the app is already
    /// there by the time a link reaches it.
    func bringToFront() {}

    /// Sync setup, as an action sheet rather than a sheet of its own: there are two things
    /// to do (point it at a folder, turn it off) and the folder picker is a whole screen of
    /// its own already. The status line lives on the settings page, which is where the user
    /// came from.
    func presentSyncSetup() {
        let sheet = UIAlertController(title: "Sync", message: sync.summary,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: sync.isOn ? "Choose a different folder…"
                                                       : "Choose a folder…",
                                      style: .default) { [weak self] _ in
            self?.presentFolderPicker()
        })
        if sync.isOn {
            sheet.addAction(UIAlertAction(title: "Turn off sync", style: .destructive) { [weak self] _ in
                self?.sync.turnOff()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // An action sheet has nowhere to point on an iPad; anchor it to the middle of the
        // page rather than letting UIKit raise an exception about a missing source.
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        present(sheet, animated: true)
    }

    private func presentFolderPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        sync.choose(url)
        // The settings page shows sync's state, and it is what the user is looking at.
        self.controller.syncStatusChanged()
    }
}
