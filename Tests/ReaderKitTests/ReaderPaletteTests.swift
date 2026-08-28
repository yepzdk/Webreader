import XCTest
@testable import ReaderKit

// `Theme.auto` follows the host's desktop palette when one is supplied (#16). Two
// guarantees carry the feature: a palette applies under `.auto` and nowhere else, and no
// palette leaves every byte of the CSS as the AppKit host has always emitted it — the
// macOS app passes nothing and must not notice this change at all.

final class ReaderPaletteTests: XCTestCase {
    // The live Omarchy "last-horizon" theme, resolved the way `OmarchyTheme` resolves it.
    private let dark = ReaderPalette(bg: "#0c0b0c", fg: "#FAFCFB", muted: "#584e51",
                                     accent: "#b59790", border: "rgba(250,252,251,0.16)",
                                     surface: "rgba(250,252,251,0.08)", isDark: true)
    // A light one, so `isDark` is exercised in both directions.
    private let light = ReaderPalette(bg: "#eff1f5", fg: "#4c4f69", muted: "#8c8fa1",
                                      accent: "#1e66f5", border: "rgba(76,79,105,0.12)",
                                      surface: "rgba(76,79,105,0.05)", isDark: false)

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
          --bg: #0c0b0c; --fg: #FAFCFB; --muted: #584e51; --accent: #b59790;
          --border: rgba(250,252,251,0.16); --surface: rgba(250,252,251,0.08);
          color-scheme: dark;
          --reader-size: 17px;
        """))
        // The stock light values are gone from `:root`; they survive only as [data-theme].
        XCTAssertFalse(css.contains(":root {\n  --bg: #fafafa;"))
    }

    func testColorSchemeFollowsIsDark() {
        XCTAssertTrue(ReaderChrome.themeCSS(ReaderSettings(), palette: light).contains("""
          --bg: #eff1f5; --fg: #4c4f69; --muted: #8c8fa1; --accent: #1e66f5;
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
          --reader-font: ui-serif, "New York", Georgia, serif;
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
    private let palette = ReaderPalette(bg: "#0c0b0c", fg: "#FAFCFB", muted: "#584e51",
                                        accent: "#b59790", border: "rgba(250,252,251,0.16)",
                                        surface: "rgba(250,252,251,0.08)", isDark: true)

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
            --bg: #0c0b0c; --fg: #FAFCFB; --muted: #584e51; --accent: #b59790;
            --accent-fg: #ffffff; --border: rgba(250,252,251,0.16);
            color-scheme: dark;
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
