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

    /// The palette a given theme paints, so a host can match a native surface to the page
    /// it sits in front of — the loading cover, and anything a later host puts beside the
    /// web view (#24).
    ///
    /// The four explicit themes ignore `prefersDark` and pin their own colours, exactly as
    /// they do in CSS; only `.auto` consults it, standing in for the `prefers-color-scheme`
    /// query the page would otherwise answer for itself.
    ///
    /// `ReaderChrome.themeCSS` renders its stylesheet from these same values, so the cover
    /// cannot drift from the document — the `LoadProgress.lineThickness` arrangement, one
    /// step further.
    public static func stock(for theme: ReaderSettings.Theme, prefersDark: Bool) -> ReaderPalette {
        switch theme {
        case .auto: return prefersDark ? stock(for: .dark, prefersDark: true)
                                       : stock(for: .light, prefersDark: false)
        case .light:
            return ReaderPalette(bg: "#fafafa", fg: "#1c1c1e", muted: "#6b6b70",
                                 accent: "#2563eb", border: "rgba(0,0,0,0.12)",
                                 surface: "rgba(0,0,0,0.05)", isDark: false)
        case .sepia:
            return ReaderPalette(bg: "#f4ecd8", fg: "#3d3225", muted: "#6f6049",
                                 accent: "#2563eb", border: "rgba(61,50,37,0.18)",
                                 surface: "rgba(61,50,37,0.07)", isDark: false)
        case .dark:
            return ReaderPalette(bg: "#1c1c1e", fg: "#f2f2f7", muted: "#9a9aa0",
                                 accent: "#3b82f6", border: "rgba(255,255,255,0.16)",
                                 surface: "rgba(255,255,255,0.08)", isDark: true)
        case .black:
            return ReaderPalette(bg: "#000000", fg: "#f2f2f7", muted: "#98989e",
                                 accent: "#3b82f6", border: "rgba(255,255,255,0.18)",
                                 surface: "rgba(255,255,255,0.10)", isDark: true)
        }
    }

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
