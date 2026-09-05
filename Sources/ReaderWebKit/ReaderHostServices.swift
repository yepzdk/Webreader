import Foundation
import ReaderKit

/// What the shell around a `ReaderWebController` has to answer for.
///
/// The controller owns everything WebKit: the page state machine, the extraction flow, the
/// script messages. What it cannot own is the handful of things that have no cross-platform
/// spelling — a rejection is a beep on a Mac and a haptic on a phone, a foreign scheme goes
/// to `NSWorkspace` or to `UIApplication`. Those are the only holes in the contract, and
/// they are holes precisely because AppKit and UIKit disagree about them; anything both
/// frameworks spell the same way stays in the controller, where it is written once.
public protocol ReaderHostServices: AnyObject {
    /// The app said no: a URL that isn't one, a selection that can't be hidden, a page that
    /// wouldn't extract when the user explicitly asked. It is the only feedback these paths
    /// give, so a shell that does nothing here makes the refusals invisible.
    func reject()

    /// A scheme the web view cannot render (`mailto:`, `msteams:`, …) — hand it to whatever
    /// owns it.
    func openExternally(_ url: URL)

    /// A link arrived from outside while the app was in the background.
    func bringToFront()

    /// The settings page asked for sync setup. The folder picker is native on every host, so
    /// the shell presents it.
    func presentSyncSetup()
}

/// The plain "Loading" screen that stands in for a site while it loads (#24).
///
/// Deliberately native on every host rather than a generated page: a `loadHTMLString` cover
/// would be a back/forward entry, would consume the navigation as "one of our own pages
/// landed", and would drive the progress line to full. Optional on the controller — a host
/// may ship without one, as the GTK host originally did.
public protocol ReaderLoadingCover: AnyObject {
    func show(theme: ReaderSettings.Theme)
    func hide()
}

/// The sync controller, as the reader sees it. The engine is shared (`ReaderKit.Sync`) but
/// how a folder is reached is not: macOS resolves a plain bookmark, iOS needs a
/// security-scoped one, and the picker differs. Nil means this host has no sync yet, which
/// the settings page already understands — it omits the section when the summary is empty.
public protocol ReaderSyncBridge: AnyObject {
    /// Something worth publishing changed locally. Debounced by the implementation.
    func localStateChanged()
    /// The start page came up — a good moment to pull, since recents are what it shows.
    func startPageShown()
    /// The chosen folder, display form, or nil when sync is off.
    var folderDisplayPath: String? { get }
    /// One sentence describing sync's state, shared by the settings page and the sheet.
    var summary: String { get }
}
