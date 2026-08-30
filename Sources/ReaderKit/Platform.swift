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
    case macOS, linux

    /// The reading serif stack.
    ///
    /// Linux picks Noto Serif ahead of Liberation Serif because it ships a real Bold. The
    /// reader sets inline quotations in medium weight (see the quotation comment in
    /// `ReaderPage.html`), and a face without one gets a synthesized smear instead of a
    /// weight — the same reason the comment there notes New York has one and Georgia
    /// doesn't. Liberation Serif stays as the fallback since it is installed everywhere.
    public var serifStack: String {
        switch self {
        case .macOS: return "ui-serif, \"New York\", Georgia, serif"
        case .linux: return "\"Noto Serif\", \"Liberation Serif\", serif"
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
        case .macOS: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Arial, sans-serif"
        case .linux: return "\"Adwaita Sans\", \"Noto Sans\", sans-serif"
        }
    }
}
