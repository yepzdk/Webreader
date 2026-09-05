import Foundation

/// Which host platform a generated page is being rendered for. It selects the CSS font
/// stacks, because the faces a page can actually name differ per system and a single
/// "cross-platform" stack degrades on both: naming Apple faces first costs nothing on
/// Linux only if something after them resolves, and on a stock Arch/Omarchy box nothing
/// in the Apple stack does — every entry falls through to Liberation, which is not a
/// choice so much as the absence of one.
///
/// This is a value, not `#if os(Linux)`, on purpose. The stack must follow the machine
/// the page is *displayed* on, not the one that compiled ReaderKit: the tests assert both
/// platforms' stacks from whichever OS the suite happens to run on, and a host that isn't
/// Swift at all can ask for either. Platform branching at compile time would make one of
/// the two untestable and unreachable.
public enum Platform: String, Sendable, CaseIterable {
    case macOS, linux, iOS, android

    /// Whether the host binds the keyboard commands the settings page's shortcut reference
    /// lists. The two desktop hosts do — a real menu bar on macOS, GSimpleAction
    /// accelerators on Linux — and the touch hosts do not: there is no menu to read the
    /// chords off and, on a phone, no key to press. A reference table listing chords that
    /// do not exist is worse than no table, so `shortcutSection` renders nothing here and
    /// the start page drops its clipboard hint.
    ///
    /// Deliberately a property of the platform rather than a `@media` query. Whether a
    /// chord is *bound* is a fact about the host application; whether a pointer can hover
    /// is a fact about the input device, and the CSS asks that question itself. An iPad
    /// with a Magic Keyboard still has no menu bar and still binds none of these.
    public var hasKeyboardCommands: Bool {
        switch self {
        case .macOS, .linux: return true
        case .iOS, .android: return false
        }
    }

    /// The reading serif stack.
    ///
    /// Linux picks Noto Serif ahead of Liberation Serif because it ships a real Bold. The
    /// reader sets inline quotations in medium weight (see the quotation comment in
    /// `ReaderPage.html`), and a face without one gets a synthesized smear instead of a
    /// weight — the same reason the comment there notes New York has one and Georgia
    /// doesn't. Liberation Serif stays as the fallback since it is installed everywhere.
    public var serifStack: String {
        switch self {
        // iOS ships the same reading faces as macOS — ui-serif resolves to New York on
        // both — so the stack is shared rather than forked into a copy that would drift.
        case .macOS, .iOS: return "ui-serif, \"New York\", Georgia, serif"
        case .linux: return "\"Noto Serif\", \"Liberation Serif\", serif"
        // Noto Serif is part of every Android system image and has a real Bold, which the
        // reader's medium-weight inline quotations need for the same reason Linux picks it
        // over Liberation. Georgia sits behind it for the OEM images that substitute it.
        case .android: return "\"Noto Serif\", Georgia, serif"
        }
    }

    /// The UI/meta sans stack.
    ///
    /// Adwaita Sans is GTK4's UI font, so on Linux it does what `-apple-system` does on
    /// macOS: the page's chrome reads as part of the desktop rather than as a web page
    /// wearing a system font's name. Inter and Cantarell are deliberately absent — neither
    /// resolves on a stock Arch/Omarchy install, and an unresolvable name is only noise.
    public var sansStack: String {
        switch self {
        case .macOS, .iOS: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Arial, sans-serif"
        case .linux: return "\"Adwaita Sans\", \"Noto Sans\", sans-serif"
        // Roboto is Android's UI font, so naming it does what -apple-system does on Apple
        // platforms: the chrome reads as part of the system rather than as a web page.
        // Noto Sans covers the OEM images that ship a substitute.
        case .android: return "Roboto, \"Noto Sans\", sans-serif"
        }
    }
}
