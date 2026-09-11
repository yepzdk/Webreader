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
    public static func stock(for theme: ReaderSettings.Theme, prefersDark: Bool,
                             accent: ReaderSettings.Accent = .blue,
                             highlight: ReaderSettings.Highlight = .bright) -> ReaderPalette {
        switch theme {
        case .auto:
            return prefersDark
                ? stock(for: .dark, prefersDark: true, accent: accent, highlight: highlight)
                : stock(for: .light, prefersDark: false, accent: accent, highlight: highlight)
        case .light:
            return ReaderPalette(bg: "#fafafa", fg: "#1c1c1e", muted: "#6b6b70",
                                 accent: hex(accent, on: .light, highlight: highlight),
                                 border: "rgba(0,0,0,0.12)",
                                 surface: "rgba(0,0,0,0.05)", isDark: false)
        case .sepia:
            return ReaderPalette(bg: "#f4ecd8", fg: "#3d3225", muted: "#6f6049",
                                 accent: hex(accent, on: .sepia, highlight: highlight),
                                 border: "rgba(61,50,37,0.18)",
                                 surface: "rgba(61,50,37,0.07)", isDark: false)
        case .dark:
            return ReaderPalette(bg: "#1c1c1e", fg: "#f2f2f7", muted: "#9a9aa0",
                                 accent: hex(accent, on: .dark, highlight: highlight),
                                 border: "rgba(255,255,255,0.16)",
                                 surface: "rgba(255,255,255,0.08)", isDark: true)
        case .black:
            return ReaderPalette(bg: "#000000", fg: "#f2f2f7", muted: "#98989e",
                                 accent: hex(accent, on: .black, highlight: highlight),
                                 border: "rgba(255,255,255,0.18)",
                                 surface: "rgba(255,255,255,0.10)", isDark: true)
        }
    }

    /// The accent's hex for one theme at one strength.
    ///
    /// A table rather than a formula: the same colour cannot serve a near-white page and a
    /// black one, and picking a shade that clears 4.5:1 against that theme's background is
    /// a judgement made once, here, with the measured ratio beside it. `ReaderPaletteTests`
    /// recomputes every pair.
    ///
    /// Two axes, because they are two questions. The hue is *which* colour; the highlight
    /// is *how much of it*:
    ///
    /// - `.text` ignores the hue and answers the body colour, so only the underline marks
    ///   a link. Returned by `stock` rather than from this table, which has no theme ink.
    /// - `.bright` is the saturated set 0.13.0 shipped, 4.5-6.4:1.
    /// - `.tinted` is the ink with the hue mixed in at the ink's own lightness. It reads as
    ///   prose, not as a colour, and lands within a point or two of the body text's own
    ///   contrast — 8:1 at worst, on sepia, where the ink itself is 10.6:1.
    /// - `.hushed` is the quietest a colour can be and still carry a link on its own:
    ///   every value is solved to 4.8:1, just past the floor.
    ///
    /// The hues are spread deliberately — 222, 188, 288, 22, 112 degrees — because at
    /// `.hushed`'s 28% saturation a narrower spread makes blue and violet the same swatch.
    static func hex(_ accent: ReaderSettings.Accent, on theme: ReaderSettings.Theme,
                    highlight: ReaderSettings.Highlight = .bright) -> String {
        switch highlight {
        case .text: return stock(for: theme, prefersDark: false).fg
        case .bright: return bright(accent, on: theme)
        case .tinted: return tinted(accent, on: theme)
        case .hushed: return hushed(accent, on: theme)
        }
    }

    /// Blue's light, dark and black values are the ones the reader has always had. Its
    /// sepia value is not: `#2563eb` measured 4.39:1 on `#f4ecd8`, which is under the bar
    /// for body text, and a link is body text.
    private static func bright(_ accent: ReaderSettings.Accent,
                               on theme: ReaderSettings.Theme) -> String {
        switch accent {
        case .blue:
            switch theme {
            case .light: return "#2563eb"   // 4.95:1
            case .sepia: return "#1d4ed8"   // 5.69:1
            case .dark:  return "#3b82f6"   // 4.63:1
            default:     return "#3b82f6"   // 5.71:1 on black
            }
        case .teal:
            switch theme {
            case .light: return "#0f766e"   // 5.24:1
            case .sepia: return "#0f766e"   // 4.65:1
            case .dark:  return "#0d9488"   // 4.54:1
            default:     return "#0d9488"   // 5.61:1 on black
            }
        case .violet:
            switch theme {
            case .light: return "#7c3aed"   // 5.46:1
            case .sepia: return "#7c3aed"   // 4.84:1
            case .dark:  return "#a78bfa"   // 6.25:1
            default:     return "#8b5cf6"   // 4.96:1 on black
            }
        case .rust:
            switch theme {
            case .light: return "#c2410c"   // 4.96:1
            case .sepia: return "#9a3412"   // 6.21:1
            case .dark:  return "#ea580c"   // 4.78:1
            default:     return "#ea580c"   // 5.9:1 on black
            }
        case .moss:
            switch theme {
            case .light: return "#15803d"   // 4.81:1
            case .sepia: return "#166534"   // 6.06:1
            case .dark:  return "#16a34a"   // 5.16:1
            default:     return "#16a34a"   // 6.37:1 on black
            }
        }
    }

    /// The theme's ink with the hue mixed in at that ink's lightness, which is why these
    /// are near-black on a pale page and near-white on a dark one. A link is a shade of the
    /// prose rather than a colour beside it; the underline does the marking.
    private static func tinted(_ accent: ReaderSettings.Accent,
                               on theme: ReaderSettings.Theme) -> String {
        switch accent {
        case .blue:
            switch theme {
            case .light: return "#0a1530"   // 17.30:1
            case .sepia: return "#112451"   // 12.79:1
            case .dark:  return "#eef2fb"   // 15.17:1
            default:     return "#eef2fb"   // 18.73:1 on black
            }
        case .teal:
            switch theme {
            case .light: return "#0a2b30"   // 14.36:1
            case .sepia: return "#114851"   // 8.62:1
            case .dark:  return "#eefafb"   // 15.96:1
            default:     return "#eefafb"   // 19.70:1 on black
            }
        case .violet:
            switch theme {
            case .light: return "#280a30"   // 17.10:1
            case .sepia: return "#441151"   // 12.35:1
            case .dark:  return "#f9eefb"   // 15.11:1
            default:     return "#f9eefb"   // 18.65:1 on black
            }
        case .rust:
            switch theme {
            case .light: return "#30180a"   // 15.96:1
            case .sepia: return "#512911"   // 10.65:1
            case .dark:  return "#fbf3ee"   // 15.52:1
            default:     return "#fbf3ee"   // 19.16:1 on black
            }
        case .moss:
            switch theme {
            case .light: return "#0f300a"   // 13.90:1
            case .sepia: return "#1a5111"   // 8.00:1
            case .dark:  return "#effbee"   // 15.96:1
            default:     return "#effbee"   // 19.70:1 on black
            }
        }
    }

    /// Every value solved to 4.8:1 against its own background at 28% saturation — the
    /// quietest a link can be and still be a colour rather than a shade of the text.
    private static func hushed(_ accent: ReaderSettings.Accent,
                               on theme: ReaderSettings.Theme) -> String {
        switch accent {
        case .blue:
            switch theme {
            case .light: return "#5a6f9f"   // 4.78:1
            case .sepia: return "#536694"   // 4.83:1
            case .dark:  return "#7588b2"   // 4.80:1
            default:     return "#6478a8"   // 4.79:1 on black
            }
        case .teal:
            switch theme {
            case .light: return "#47767e"   // 4.84:1
            case .sepia: return "#426e75"   // 4.80:1
            case .dark:  return "#57919b"   // 4.80:1
            default:     return "#4d8188"   // 4.81:1 on black
            }
        case .violet:
            switch theme {
            case .light: return "#925a9f"   // 4.81:1
            case .sepia: return "#875394"   // 4.83:1
            case .dark:  return "#a677b2"   // 4.78:1
            default:     return "#9b64a8"   // 4.78:1 on black
            }
        case .rust:
            switch theme {
            case .light: return "#8e6750"   // 4.78:1
            case .sepia: return "#835f4a"   // 4.82:1
            case .dark:  return "#aa7f67"   // 4.81:1
            default:     return "#9a6f57"   // 4.79:1 on black
            }
        case .moss:
            switch theme {
            case .light: return "#4c7a45"   // 4.82:1
            case .sepia: return "#467140"   // 4.83:1
            case .dark:  return "#5d9654"   // 4.83:1
            default:     return "#52854b"   // 4.82:1 on black
            }
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
