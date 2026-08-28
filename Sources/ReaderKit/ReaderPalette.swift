import Foundation

/// A colour palette supplied by the host for `Theme.auto`.
///
/// `auto` used to mean one bit — light or dark — resolved in CSS by
/// `@media (prefers-color-scheme: dark)`. On a desktop that themes every application from
/// one palette (Omarchy, see `OmarchyTheme` in the GTK host) that bit is a poor answer: the
/// reader renders in generic system grey beside a terminal, a bar and a browser that all
/// wear the user's chosen colours. Passing the resolved palette in lets `auto` mean "match
/// this desktop" instead of "match this desktop's light/dark switch".
///
/// It is a plain value, not a lookup: ReaderKit stays Foundation-only and knows nothing
/// about where the colours came from, which keeps the page generators testable and lets a
/// second host (GNOME's accent colour, a future iOS tint) supply one the same way.
/// A host that has nothing to say passes `nil` and the `prefers-color-scheme` fallback
/// stands, exactly as on macOS.
///
/// The six roles are the six CSS custom properties every generated page already reads, so
/// a palette needs no new stylesheet — see `ReaderChrome.themeCSS`. Only `auto` honours it;
/// the explicit themes exist precisely to pin a palette regardless of the desktop.
public struct ReaderPalette: Equatable, Sendable {
    /// Page background. Omarchy `background`.
    public let bg: String
    /// Body text. Omarchy `foreground`.
    public let fg: String
    /// Secondary text — bylines, hints, disabled chrome. Omarchy `muted`.
    public let muted: String
    /// Links, focus rings and the pressed state of the chrome buttons. Omarchy `accent`.
    public let accent: String
    /// Hairlines and control outlines. No Omarchy counterpart: it is an alpha overlay of
    /// the foreground, synthesised by the host at the same alpha the stock palettes use.
    public let border: String
    /// Raised fills — popovers, the recents rows, the badge. Also a synthesised foreground
    /// overlay, one step lighter than `border`.
    public let surface: String
    /// Whether this palette reads as dark. Drives `color-scheme`, so form controls,
    /// scrollbars and the default canvas match rather than staying stubbornly light.
    public let isDark: Bool

    public init(bg: String, fg: String, muted: String, accent: String,
                border: String, surface: String, isDark: Bool) {
        self.bg = bg
        self.fg = fg
        self.muted = muted
        self.accent = accent
        self.border = border
        self.surface = surface
        self.isDark = isDark
    }
}
