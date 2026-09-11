import Foundation
import XCTest
@testable import ReaderKit

// `Theme.auto` follows the host's desktop palette when one is supplied (#16). Two
// guarantees carry the feature: a palette applies under `.auto` and nowhere else, and no
// palette leaves every byte of the CSS as the AppKit host has always emitted it — the
// macOS app passes nothing and must not notice this change at all.

/// The live Omarchy "last-horizon" theme (dark), resolved the way `OmarchyTheme` resolves
/// it. `--muted` is the theme's foreground blended toward its background, not the theme's
/// own `muted` key — that key is `#584e51`, a UI dim colour equal to this theme's
/// `selection`, and it measures 2.45:1 against `#0c0b0c`.
private let lastHorizon = ReaderPalette(bg: "#0c0b0c", fg: "#FAFCFB", muted: "#9b9c9c",
                                        accent: "#b59790", border: "rgba(250,252,251,0.16)",
                                        surface: "rgba(250,252,251,0.08)", isDark: true)

/// Catppuccin Latte, a shipped Omarchy theme declaring `mode = "light"`, so `isDark` and
/// the blend are both exercised in the other direction. Its own foreground is only 7.06:1
/// on its background, which is what makes the blend stop short of the full 40%.
private let catppuccinLatte = ReaderPalette(bg: "#eff1f5", fg: "#4c4f69", muted: "#696c82",
                                            accent: "#1e66f5", border: "rgba(76,79,105,0.12)",
                                            surface: "rgba(76,79,105,0.05)", isDark: false)

final class ReaderPaletteTests: XCTestCase {
    private let dark = lastHorizon
    private let light = catppuccinLatte

    private func settings(_ theme: ReaderSettings.Theme) -> ReaderSettings {
        var s = ReaderSettings()
        s.theme = theme
        return s
    }

    // MARK: - The auto path

    func testAutoPaletteLandsOnRoot() {
        let css = ReaderChrome.themeCSS(ReaderSettings(), palette: dark)
        // The whole block, in order: the palette replaces the light defaults outright
        // rather than being appended after them.
        XCTAssertTrue(css.hasPrefix("""
        :root {
          --bg: #0c0b0c; --fg: #FAFCFB; --muted: #9b9c9c; --accent: #b59790;
          --border: rgba(250,252,251,0.16); --surface: rgba(250,252,251,0.08);
          color-scheme: dark;
          --reader-size: 17px;
        """))
        // The stock light values are gone from `:root`; they survive only as [data-theme].
        XCTAssertFalse(css.contains(":root {\n  --bg: #fafafa;"))
    }

    func testColorSchemeFollowsIsDark() {
        XCTAssertTrue(ReaderChrome.themeCSS(ReaderSettings(), palette: light).contains("""
          --bg: #eff1f5; --fg: #4c4f69; --muted: #696c82; --accent: #1e66f5;
          --border: rgba(76,79,105,0.12); --surface: rgba(76,79,105,0.05);
          color-scheme: light;
        """))
        XCTAssertTrue(ReaderChrome.themeCSS(ReaderSettings(), palette: dark)
            .contains("--surface: rgba(250,252,251,0.08);\n  color-scheme: dark;"))
    }

    func testAutoPaletteReplacesTheSystemFallback() {
        // The palette has already answered the light/dark question. Leaving the media
        // query behind it would repaint a light desktop's reader the moment the system
        // switch flipped, which is precisely the coupling this feature removes.
        XCTAssertFalse(ReaderChrome.themeCSS(ReaderSettings(), palette: dark)
            .contains("prefers-color-scheme"))
        XCTAssertFalse(ReaderChrome.themeCSS(ReaderSettings(), palette: light)
            .contains("prefers-color-scheme"))
        XCTAssertTrue(ReaderChrome.themeCSS(ReaderSettings()).contains("prefers-color-scheme"))
    }

    func testAutoPaletteKeepsTheExplicitThemesInTheDocument() {
        // The Aa popover sets data-theme live, with no reload, so all four palettes must
        // already be in the stylesheet even when the page renders under a hosted one.
        let css = ReaderChrome.themeCSS(ReaderSettings(), palette: dark)
        for theme in ["light", "sepia", "dark", "black"] {
            XCTAssertTrue(css.contains(":root[data-theme=\"\(theme)\"]"), theme)
        }
    }

    // MARK: - The explicit themes

    func testExplicitThemesIgnoreThePaletteEntirely() {
        // An explicit theme exists to pin its own colours regardless of the desktop; if a
        // palette could reach one, picking Sepia on a dark desktop would do nothing.
        for theme in ReaderSettings.Theme.allCases where theme != .auto {
            let pinned = settings(theme)
            XCTAssertEqual(ReaderChrome.themeCSS(pinned, palette: dark),
                           ReaderChrome.themeCSS(pinned), theme.rawValue)
            XCTAssertFalse(ReaderChrome.themeCSS(pinned, palette: dark).contains("#0c0b0c"),
                           theme.rawValue)
            // And the system fallback stays, because data-theme outranks it anyway.
            XCTAssertTrue(ReaderChrome.themeCSS(pinned, palette: dark)
                .contains("prefers-color-scheme"), theme.rawValue)
        }
    }

    // MARK: - Regression guard for the macOS host

    func testNoPaletteEmitsTheStockCSSByteForByte() {
        // Frozen on purpose: the AppKit host threads no palette, so any drift here is an
        // unintended change to a shipping app's appearance.
        XCTAssertEqual(ReaderChrome.themeCSS(ReaderSettings()), #"""
        :root {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #5a6f9f;
          --border: rgba(0,0,0,0.12); --surface: rgba(0,0,0,0.05);
          --reader-size: 17px;
          --reader-leading: 1.6;
          --reader-width: 42rem;
          --reader-gutter: 6%;
          --reader-font: ui-serif, "New York", Georgia, serif;
          --safe-top: env(safe-area-inset-top, 0px);
          --safe-bottom: env(safe-area-inset-bottom, 0px);
          --safe-left: env(safe-area-inset-left, 0px);
          --safe-right: env(safe-area-inset-right, 0px);
        }
        .swatch-blue { background: #5a6f9f; }
        .swatch-teal { background: #47767e; }
        .swatch-violet { background: #925a9f; }
        .swatch-rust { background: #8e6750; }
        .swatch-moss { background: #4c7a45; }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #7588b2;
            --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          }
        :root:not([data-theme]) .swatch-blue { background: #7588b2; }
          :root:not([data-theme]) .swatch-teal { background: #57919b; }
          :root:not([data-theme]) .swatch-violet { background: #a677b2; }
          :root:not([data-theme]) .swatch-rust { background: #aa7f67; }
          :root:not([data-theme]) .swatch-moss { background: #5d9654; }
        }
        /* Explicit themes pin a palette; the attribute selector outranks both the
           light defaults and the dark media query above. */
        :root[data-theme="light"] {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #5a6f9f;
          --border: rgba(0,0,0,0.12); --surface: rgba(0,0,0,0.05);
          color-scheme: light;
        }
        :root[data-theme="light"] .swatch-blue { background: #5a6f9f; }
        :root[data-theme="light"] .swatch-teal { background: #47767e; }
        :root[data-theme="light"] .swatch-violet { background: #925a9f; }
        :root[data-theme="light"] .swatch-rust { background: #8e6750; }
        :root[data-theme="light"] .swatch-moss { background: #4c7a45; }
        :root[data-theme="sepia"] {
          --bg: #f4ecd8; --fg: #3d3225; --muted: #6f6049; --accent: #536694;
          --border: rgba(61,50,37,0.18); --surface: rgba(61,50,37,0.07);
          color-scheme: light;
        }
        :root[data-theme="sepia"] .swatch-blue { background: #536694; }
        :root[data-theme="sepia"] .swatch-teal { background: #426e75; }
        :root[data-theme="sepia"] .swatch-violet { background: #875394; }
        :root[data-theme="sepia"] .swatch-rust { background: #835f4a; }
        :root[data-theme="sepia"] .swatch-moss { background: #467140; }
        :root[data-theme="dark"] {
          --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #7588b2;
          --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          color-scheme: dark;
        }
        :root[data-theme="dark"] .swatch-blue { background: #7588b2; }
        :root[data-theme="dark"] .swatch-teal { background: #57919b; }
        :root[data-theme="dark"] .swatch-violet { background: #a677b2; }
        :root[data-theme="dark"] .swatch-rust { background: #aa7f67; }
        :root[data-theme="dark"] .swatch-moss { background: #5d9654; }
        :root[data-theme="black"] {
          --bg: #000000; --fg: #f2f2f7; --muted: #98989e; --accent: #6478a8;
          --border: rgba(255,255,255,0.18); --surface: rgba(255,255,255,0.10);
          color-scheme: dark;
        }
        :root[data-theme="black"] .swatch-blue { background: #6478a8; }
        :root[data-theme="black"] .swatch-teal { background: #4d8188; }
        :root[data-theme="black"] .swatch-violet { background: #9b64a8; }
        :root[data-theme="black"] .swatch-rust { background: #9a6f57; }
        :root[data-theme="black"] .swatch-moss { background: #52854b; }
        """#)
    }
}

/// Every generated page takes the palette the same way it takes `platform:` — last, and
/// defaulted, so the AppKit host's call sites keep compiling untouched.
final class ReaderPalettePageTests: XCTestCase {
    private let article = Article(title: "T", byline: "By A", siteName: "S",
                                  content: "<p>x</p>")
    private let palette = lastHorizon

    private func pagesWithPalette() -> [String: String] {
        [
            "reader": ReaderPage.html(article: article, platform: .linux, palette: palette),
            "start": StartPage.html(appName: "Reader", platform: .linux, palette: palette),
            "settings": SettingsPage.html(appName: "Reader", platform: .linux, palette: palette),
        ]
    }

    private func pagesWithoutPalette() -> [String: String] {
        [
            "reader": ReaderPage.html(article: article, platform: .linux),
            "start": StartPage.html(appName: "Reader", platform: .linux),
            "settings": SettingsPage.html(appName: "Reader", platform: .linux),
        ]
    }

    func testEveryPageCarriesThePaletteUnderAuto() {
        for (name, html) in pagesWithPalette() {
            XCTAssertTrue(html.contains("--bg: #0c0b0c;"), name)
            XCTAssertTrue(html.contains("--surface: rgba(250,252,251,0.08);"), name)
            XCTAssertTrue(html.contains("--border: rgba(250,252,251,0.16);"), name)
            // The *stylesheet* must not second-guess a palette the host resolved — that is
            // the flicker this guards. The script may still ask the same question: with a
            // desktop palette in force `paintAccent` returns before it does, and on every
            // other page it is how `auto` picks which row of the accent table to paint.
            XCTAssertFalse(html.contains("@media (prefers-color-scheme"), name)
        }
    }

    func testEveryPageIsUnchangedWithoutOne() {
        for (name, html) in pagesWithoutPalette() {
            XCTAssertTrue(html.contains("--bg: #fafafa;"), name)
            XCTAssertTrue(html.contains("@media (prefers-color-scheme: dark)"), name)
            XCTAssertFalse(html.contains("#0c0b0c"), name)
        }
    }

    func testAnExplicitThemePageIgnoresThePalette() {
        var pinned = ReaderSettings()
        pinned.theme = .sepia
        XCTAssertEqual(StartPage.html(appName: "Reader", settings: pinned, palette: palette),
                       StartPage.html(appName: "Reader", settings: pinned))
    }

    // MARK: - The offline page, which has no settings and so is permanently auto

    func testOfflinePageTakesThePaletteUnconditionally() {
        let html = OfflineFallback.html(appName: "Reader", host: "example.com",
                                        kind: .offline, palette: palette)
        XCTAssertTrue(html.contains("""
          :root {
            --bg: #0c0b0c; --fg: #FAFCFB; --muted: #9b9c9c; --accent: #b59790;
            --surface: rgba(250,252,251,0.08); --border: rgba(250,252,251,0.16);
            color-scheme: dark;
            --safe-top: env(safe-area-inset-top, 0px);
            --safe-bottom: env(safe-area-inset-bottom, 0px);
            --safe-left: env(safe-area-inset-left, 0px);
            --safe-right: env(safe-area-inset-right, 0px);
          }
        """))
        XCTAssertFalse(html.contains("prefers-color-scheme"))
    }

    func testOfflinePageIsUnchangedWithoutOne() {
        let html = OfflineFallback.html(appName: "Reader", host: "example.com", kind: .offline)
        XCTAssertTrue(html.contains("""
          :root {
            --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
            --surface: rgba(0,0,0,0.05); --border: rgba(0,0,0,0.12);
            --safe-top: env(safe-area-inset-top, 0px);
            --safe-bottom: env(safe-area-inset-bottom, 0px);
            --safe-left: env(safe-area-inset-left, 0px);
            --safe-right: env(safe-area-inset-right, 0px);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
              --surface: rgba(255,255,255,0.08); --border: rgba(255,255,255,0.16);
            }
          }
        """))
    }

    func testNoPagePutsALabelOnTopOfTheAccent() {
        // The rule, asserted where it can actually be broken. A filled accent button reads
        // fine until the highlight follows the text: on black, "Open" was a white label on
        // a near-white fill. So the accent is a border and a label, never a fill under one
        // — and the only fills left are the page's own surfaces.
        let pages = [
            "start": StartPage.html(appName: "R"),
            "settings": SettingsPage.html(appName: "R"),
            "offline": OfflineFallback.html(appName: "R", host: "e.com", kind: .offline),
            "reader": ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                       content: "<p>x</p>", hiddenHits: [:],
                                                       image: nil)),
        ]
        for (name, html) in pages {
            for offender in ["color: #fff; background: var(--accent)",
                             "color: var(--accent-fg)",
                             "background: var(--accent); color: var(--bg)"] {
                XCTAssertFalse(html.contains(offender),
                               "\(name) still paints a label on the accent: \(offender)")
            }
        }
    }

    func testTheStartPageAnswersToTheReadingControls() {
        // Five of the seven controls did nothing here: the page was pinned to 34rem, a sans
        // stack and 12px rows whatever the reader had chosen, so only the theme and the
        // highlight showed any effect at all.
        let page = StartPage.html(appName: "R")
        XCTAssertTrue(page.contains("max-width: var(--reader-width);"))
        XCTAssertTrue(page.contains("font-family: var(--reader-font);"))
        XCTAssertTrue(page.contains("font-size: calc(var(--reader-size) * 0.82);"))
        XCTAssertTrue(page.contains("line-height: var(--reader-leading);"))
        // Quotes is the one that cannot mean anything without prose, so it is not offered
        // here — a control that does nothing where it is drawn is worse than no control.
        XCTAssertFalse(page.contains("data-key=\"quoteStyle\""),
                       "the start page has no blockquote to style")
        XCTAssertTrue(ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                       content: "<p>x</p>", hiddenHits: [:],
                                                       image: nil))
            .contains("data-key=\"quoteStyle\""))
    }
}

/// WCAG 2.1 contrast, so "is this readable" can be asserted rather than eyeballed.
///
/// A second implementation of the maths in `OmarchyTheme.secondaryText(fg:bg:)`, which is
/// where the host derives `--muted`. The two cannot share one: that helper lives in the
/// `WebReaderGTK` host target, which these tests do not link, and `ReaderKit` is
/// Foundation-only and performs no colour maths of its own. They meet here instead, on the
/// palettes the host produces — which is the only place the answer actually matters.
private enum WCAG {
    /// Contrast ratio between two `#rrggbb` colours: 1 (identical) to 21 (black on white).
    /// AA for normal text is 4.5.
    static func contrast(_ a: String, on b: String) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        let linear = stride(from: 0, to: 6, by: 2).map { index -> Double in
            let channel = Double(Int(String(digits[index ... index + 1]), radix: 16) ?? 0) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

/// `--muted` is secondary body *text* — feed hostnames under each start-page headline,
/// bylines, phrase counts — so it has to be readable, not merely dimmer.
///
/// The host used to fill it from Omarchy's `muted` key, which is a UI dim colour, and on
/// the live `last-horizon` theme that put every hostname at 2.45:1 on `#0c0b0c`. Nothing
/// caught it because nothing measured it. These tests measure it.
final class ReaderPaletteContrastTests: XCTestCase {
    /// WCAG AA for normal text. `--muted` is 11px on the start page, so this is the floor
    /// that applies — the 3:1 large-text allowance is not available to it.
    private let minimum = 4.5

    func testTheContrastHelperMatchesTheKnownExtremes() {
        XCTAssertEqual(WCAG.contrast("#000000", on: "#ffffff"), 21, accuracy: 0.001)
        XCTAssertEqual(WCAG.contrast("#0c0b0c", on: "#0c0b0c"), 1, accuracy: 0.001)
        // The stock dark palette, which the blend is calibrated against.
        XCTAssertEqual(WCAG.contrast("#9a9aa0", on: "#1c1c1e"), 6.08, accuracy: 0.01)
    }

    func testSecondaryTextClearsAAOnTheLiveDarkTheme() {
        let ratio = WCAG.contrast(lastHorizon.muted, on: lastHorizon.bg)
        XCTAssertGreaterThanOrEqual(ratio, minimum, "last-horizon --muted is \(ratio):1")
    }

    func testSecondaryTextClearsAAOnALightTheme() {
        // The blend is a proportional mix toward the background, so it needs no light/dark
        // branch — but a light theme is where the foreground has the least headroom to
        // spend, so it is the direction that has to be checked rather than assumed.
        let ratio = WCAG.contrast(catppuccinLatte.muted, on: catppuccinLatte.bg)
        XCTAssertGreaterThanOrEqual(ratio, minimum, "catppuccin-latte --muted is \(ratio):1")
    }

    func testBodyTextClearsAAOnBothThemes() {
        // `--fg` comes straight from the theme and is nothing this code derives; asserting
        // it keeps the `--muted` results above honest by showing the headroom they started
        // from, and would flag a fixture typo that quietly made the blend look good.
        for palette in [lastHorizon, catppuccinLatte] {
            XCTAssertGreaterThanOrEqual(WCAG.contrast(palette.fg, on: palette.bg), minimum,
                                        palette.bg)
        }
    }

    func testTheOldMutedKeyMappingFailsTheSameAssertion() {
        // The exact pairing that shipped: Omarchy's `muted` key on its `background`, for
        // the theme this box runs. If a future change reads that key again, the two tests
        // above go red — this one states why, and fails if the defect is ever "fixed" by
        // relaxing the threshold instead.
        let ratio = WCAG.contrast("#584e51", on: "#0c0b0c")
        XCTAssertEqual(ratio, 2.45, accuracy: 0.01)
        XCTAssertLessThan(ratio, minimum)
    }
}

/// The native loading cover paints `ReaderPalette.stock`; the document paints
/// `ReaderChrome.themeCSS`. They read the same values, or the cover is visibly the wrong
/// colour behind a page that is about to appear (#24).
final class StockPaletteTests: XCTestCase {
    func testEveryPinnedThemeEmitsItsStockPalette() {
        for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
            var settings = ReaderSettings()
            settings.theme = theme
            let css = ReaderChrome.themeCSS(settings)
            // The palette now has two axes, and the page renders the settings' own: a
            // default reader is on `hushed`, so comparing against `bright` would say the
            // stylesheet had drifted when it had only been read at the wrong strength.
            let palette = ReaderPalette.stock(for: theme, prefersDark: false,
                                              highlight: settings.highlight)
            XCTAssertTrue(css.contains(":root[data-theme=\"\(theme.rawValue)\"] {"),
                          "\(theme.rawValue) has no pinned block")
            XCTAssertTrue(css.contains("--bg: \(palette.bg); --fg: \(palette.fg); "
                                       + "--muted: \(palette.muted); --accent: \(palette.accent);"),
                          "\(theme.rawValue) drifted from its stock palette")
            XCTAssertTrue(css.contains("--border: \(palette.border); --surface: \(palette.surface);"),
                          "\(theme.rawValue) drifted from its stock palette")
            XCTAssertTrue(css.contains("color-scheme: \(palette.isDark ? "dark" : "light");"))
        }
    }

    func testAutoResolvesToTheLightAndDarkDefaults() {
        // With no host palette the page answers light/dark in CSS; a host that has to paint
        // a surface asks `stock` the same question and must get the same two answers.
        let css = ReaderChrome.themeCSS(ReaderSettings())
        let light = ReaderPalette.stock(for: .auto, prefersDark: false)
        let dark = ReaderPalette.stock(for: .auto, prefersDark: true)
        XCTAssertFalse(light.isDark)
        XCTAssertTrue(dark.isDark)
        XCTAssertTrue(css.contains("--bg: \(light.bg);"))
        XCTAssertTrue(css.contains("--bg: \(dark.bg);"))
    }

    func testAnExplicitThemeIgnoresTheDesktopsLightDarkSwitch() {
        // The explicit themes exist precisely to pin a palette regardless of the desktop.
        for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
            XCTAssertEqual(ReaderPalette.stock(for: theme, prefersDark: false),
                           ReaderPalette.stock(for: theme, prefersDark: true))
        }
    }
}


/// Every accent, against every background it can land on.
///
/// The table in `ReaderPalette.hex` is a judgement call written down; this recomputes it.
/// A link is body text, so 4.5:1 is the bar, and the point of five vetted colours rather
/// than a colour well is that all twenty pairs can be held to it.
final class AccentContrastTests: XCTestCase {
    private func luminance(_ hex: String) -> Double {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        func channel(_ start: Int) -> Double {
            let i = h.index(h.startIndex, offsetBy: start)
            let j = h.index(i, offsetBy: 2)
            let value = Double(Int(h[i..<j], radix: 16) ?? 0) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testEveryAccentIsReadableOnEveryThemeAtEveryStrength() {
        // Eighty pairs, and the reason the control offers a list rather than a colour well:
        // every one of them can be held to the floor. An underline marks a link for someone
        // who cannot separate the hues, but the text is still text — 1.4.3 does not care
        // how the link is signalled.
        for highlight in ReaderSettings.Highlight.allCases {
            for accent in ReaderSettings.Accent.allCases {
                for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
                    let palette = ReaderPalette.stock(for: theme, prefersDark: false,
                                                      accent: accent, highlight: highlight)
                    let ratio = contrast(palette.accent, palette.bg)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(accent) \(highlight) on \(theme) is "
                        + "\(String(format: "%.2f", ratio)):1 — a link is body text")
                }
            }
        }
    }

    func testTheQuietLevelsAreActuallyQuieterThanTheLoudOne() {
        // The ladder has to be a ladder, or the control is four words for one colour. What
        // "quieter" means here is *nearer the prose*, not less saturated: a tint sits at
        // the ink's own lightness, so on a pale page it is a deep colour with a wide
        // channel spread and a naive chroma test calls it loud. Distance from the body
        // text is the thing the reader actually perceives, and the thing the levels were
        // built to order.
        func distance(_ a: String, _ b: String) -> Double {
            func channels(_ hex: String) -> [Double] {
                let h = hex.dropFirst()
                return stride(from: 0, to: 6, by: 2).map { i in
                    let s = h.index(h.startIndex, offsetBy: i)
                    return Double(Int(h[s..<h.index(s, offsetBy: 2)], radix: 16) ?? 0) / 255
                }
            }
            return zip(channels(a), channels(b))
                .map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
        }
        for accent in ReaderSettings.Accent.allCases {
            for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
                let ink = ReaderPalette.stock(for: theme, prefersDark: false).fg
                let away = { (h: ReaderSettings.Highlight) in
                    distance(ReaderPalette.hex(accent, on: theme, highlight: h), ink)
                }
                XCTAssertEqual(away(.text), 0, accuracy: 0.0001,
                               "\(accent) on \(theme) does not follow the text")
                XCTAssertLessThan(away(.tinted), away(.hushed),
                                  "tinted \(accent) on \(theme) is no nearer the prose than hushed")
                // Bright and hushed both sit far from the ink — they are colours, not
                // shades of it — so the claim there is about saturation, which is what
                // "hushed" names. The two quiet levels have to stay apart by a real
                // margin or the control offers the same answer twice: the narrowest pair
                // in the table is moss on sepia, where hushed is 1.36x further out.
                XCTAssertGreaterThan(away(.hushed), away(.tinted) * 1.3,
                                     "the two quiet levels are not distinct on \(theme)")
            }
        }
    }

    func testFollowingTheTextIsTheTextAndNotAGreyNearIt() {
        // The point of the level: a link is the prose colour exactly, so only the underline
        // marks it. A colour merely close to the ink would be the worst of both — neither a
        // signal nor an absence of one.
        for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
            for accent in ReaderSettings.Accent.allCases {
                let page = ReaderPalette.stock(for: theme, prefersDark: false,
                                               accent: accent, highlight: .text)
                XCTAssertEqual(page.accent, page.fg,
                               "\(accent) on \(theme) is near the ink rather than the ink")
            }
        }
    }

    func testBlueIsUnchangedWhereItAlreadyPassed() {
        // Nobody asked for their reader to look different: blue keeps the exact values it
        // has always had on light, dark and black.
        XCTAssertEqual(ReaderPalette.stock(for: .light, prefersDark: false).accent, "#2563eb")
        XCTAssertEqual(ReaderPalette.stock(for: .dark, prefersDark: false).accent, "#3b82f6")
        XCTAssertEqual(ReaderPalette.stock(for: .black, prefersDark: false).accent, "#3b82f6")
        // Sepia is the exception, and deliberately: #2563eb measured 4.39:1 on #f4ecd8.
        XCTAssertNotEqual(ReaderPalette.stock(for: .sepia, prefersDark: false).accent, "#2563eb")
    }

    func testTheChoiceRoundTripsAndDefaultsToBlue() {
        XCTAssertEqual(ReaderSettings().accent, .blue)
        var settings = ReaderSettings()
        settings.accent = .moss
        XCTAssertEqual(ReaderSettings.fromJSON(settings.json).accent, .moss)
        XCTAssertEqual(ReaderSettings.decode(["accent": "chartreuse"]).accent, .blue)
    }

    func testThePopoverOffersOneSwatchPerAccent() {
        let page = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                    content: "<p>x</p>", hiddenHits: [:], image: nil),
                                   settings: ReaderSettings(), history: ReaderHistory(),
                                   platform: .iOS)
        for accent in ReaderSettings.Accent.allCases {
            XCTAssertTrue(page.contains("data-key=\"accent\" data-value=\"\(accent.rawValue)\""),
                          "no swatch for \(accent)")
        }
    }

    func testTheStrengthRoundTripsAndDefaultsToHushed() {
        // Hushed by default: every reader shipped so far has been looking at `bright`, and
        // the point of the work is that it was too loud. An unknown value falls back like
        // every other setting rather than poisoning the page.
        XCTAssertEqual(ReaderSettings().highlight, .hushed)
        var settings = ReaderSettings()
        settings.highlight = .text
        XCTAssertEqual(ReaderSettings.fromJSON(settings.json).highlight, .text)
        XCTAssertEqual(ReaderSettings.decode(["highlight": "neon"]).highlight, .hushed)
        // A device that has never heard of the key keeps the default rather than losing
        // the rest of the payload — the sync blob is whole-settings, and an older peer
        // writes one without it.
        XCTAssertEqual(ReaderSettings.decode(["accent": "moss"]).highlight, .hushed)
    }

    func testThePopoverAsksTheTwoQuestionsSeparately() {
        let page = ReaderPage.html(article: Article(title: "T", byline: nil, siteName: nil,
                                                    content: "<p>x</p>", hiddenHits: [:], image: nil),
                                   settings: ReaderSettings(), history: ReaderHistory(),
                                   platform: .iOS)
        for highlight in ReaderSettings.Highlight.allCases {
            XCTAssertTrue(page.contains("data-key=\"highlight\" data-value=\"\(highlight.rawValue)\""),
                          "no control for \(highlight)")
        }
        XCTAssertTrue(page.contains(">Highlight</h3>"))
        XCTAssertTrue(page.contains(">Hue</h3>"))
        // Following the text has no hue, and the row retires rather than painting five
        // swatches nothing will use.
        XCTAssertTrue(page.contains(":root[data-highlight=\"text\"] #panelHue"))
    }

    func testTintedSwatchesCarryTheirHueOnTheRim() {
        // The fill has to be honest — it is what the page will paint — but five tints on a
        // dark page sit within 0.03 of each other, which is a row of five identical discs.
        // The rim carries the hue at the strength that can hold it. Measured, not assumed:
        // the closest tinted pair is blue and teal.
        let tinted = ReaderChrome.swatchCSS(for: .dark, highlight: .tinted)
        for accent in ReaderSettings.Accent.allCases {
            let fill = ReaderPalette.hex(accent, on: .dark, highlight: .tinted)
            let rim = ReaderPalette.hex(accent, on: .dark, highlight: .hushed)
            XCTAssertTrue(tinted.contains(".swatch-\(accent.rawValue) { background: \(fill); "
                                          + "border-color: \(rim); }"),
                          "\(accent) has no rim to tell it apart by")
        }
        // The other levels are five different colours already; a second ring there is noise.
        for level in [ReaderSettings.Highlight.bright, .hushed] {
            XCTAssertFalse(ReaderChrome.swatchCSS(for: .dark, highlight: level).contains("border-color"),
                           "\(level) does not need rims")
        }
    }

    func testTheLivePathCarriesEveryShadeThePanelCanChooseTo() {
        // The stylesheet only ever holds the pair the page was rendered with, so without
        // this table picking a colour moved the ring on a swatch and changed nothing else
        // until the next render — which is how the accent control shipped in 0.13.0.
        let table = ReaderChrome.accentTableJS
        for theme in [ReaderSettings.Theme.light, .sepia, .dark, .black] {
            for highlight in ReaderSettings.Highlight.allCases {
                for accent in ReaderSettings.Accent.allCases {
                    let hex = ReaderPalette.hex(accent, on: theme, highlight: highlight)
                    XCTAssertTrue(table.contains("\(accent.rawValue): '\(hex)'"),
                                  "\(theme) \(highlight) \(accent) is missing from the table")
                }
            }
        }
    }
}
