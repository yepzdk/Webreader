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
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
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
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
            --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          }
        }
        /* Explicit themes pin a palette; the attribute selector outranks both the
           light defaults and the dark media query above. */
        :root[data-theme="light"] {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
          --border: rgba(0,0,0,0.12); --surface: rgba(0,0,0,0.05);
          color-scheme: light;
        }
        :root[data-theme="sepia"] {
          --bg: #f4ecd8; --fg: #3d3225; --muted: #6f6049; --accent: #2563eb;
          --border: rgba(61,50,37,0.18); --surface: rgba(61,50,37,0.07);
          color-scheme: light;
        }
        :root[data-theme="dark"] {
          --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
          --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          color-scheme: dark;
        }
        :root[data-theme="black"] {
          --bg: #000000; --fg: #f2f2f7; --muted: #98989e; --accent: #3b82f6;
          --border: rgba(255,255,255,0.18); --surface: rgba(255,255,255,0.10);
          color-scheme: dark;
        }
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
            XCTAssertFalse(html.contains("prefers-color-scheme"), name)
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
            --accent-fg: #ffffff; --border: rgba(250,252,251,0.16);
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
            --accent-fg: #ffffff; --border: rgba(0,0,0,0.12);
            --safe-top: env(safe-area-inset-top, 0px);
            --safe-bottom: env(safe-area-inset-bottom, 0px);
            --safe-left: env(safe-area-inset-left, 0px);
            --safe-right: env(safe-area-inset-right, 0px);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
              --accent-fg: #ffffff; --border: rgba(255,255,255,0.16);
            }
          }
        """))
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
            let palette = ReaderPalette.stock(for: theme, prefersDark: false)
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
