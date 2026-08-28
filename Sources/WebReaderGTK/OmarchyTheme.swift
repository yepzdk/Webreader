import Foundation
import ReaderKit

/// Reads the active Omarchy theme so `Theme.auto` can mean "match this desktop" rather
/// than "match this desktop's light/dark switch" (#16).
///
/// **This reads Omarchy's internal state layout, not a versioned API.** There is no D-Bus
/// interface, no dconf key and no portal signal carrying an Omarchy theme; the state
/// directory is what every first-party consumer reads — `omarchy-theme-current`,
/// `omarchy-theme-color`, and the ~20 `omarchy-theme-set-*` helpers all resolve the same
/// files, and `omarchy-theme-color`'s own header frames them as the shared interface. So
/// it is stable in practice while being nobody's promise, which is why every failure here
/// is a `nil` and never an error: on a non-Omarchy box, or after a layout change, the page
/// falls back to `prefers-color-scheme` and looks exactly as it does on macOS. That is the
/// same graceful degradation `omarchy-theme-set-browser` performs when its own generated
/// file is missing.
///
/// A theme change is picked up on the **next render**, not live: this is a plain read with
/// no watch behind it. That is deliberate for now — a reader page is a document, and
/// repainting one under the reader mid-paragraph buys little. If a watch is ever added it
/// must be a `GFileMonitor` on the *parent* directory, `<state>/omarchy/current`, and not
/// on `colors.toml`: `omarchy-theme-set` stages the new theme elsewhere and installs it
/// with `rm -rf` + `mv`, so the file's inode is replaced on every switch and an inode
/// watch goes stale the first time it fires.
enum OmarchyTheme {
    /// The active palette, or nil when this is not an Omarchy desktop (or the theme file is
    /// missing the three colours a palette needs).
    static func current() -> ReaderPalette? {
        let file = XDG.stateDirectory()
            .appendingPathComponent("omarchy", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("theme", isDirectory: true)
            .appendingPathComponent("colors.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let keys = values(in: text)

        // The three roles Omarchy names that a reader page cannot invent: background,
        // foreground, accent. Anything less is not a palette we can render from, so we
        // decline rather than mix half a theme into the stock one. Both hexes must also
        // parse, because `--muted`, `--border` and `--surface` are all derived from them
        // and an unreadable one leaves nothing to derive. Note `muted` is *not* required:
        // see `secondaryText(fg:bg:)` for why that key is never read.
        guard let bg = keys["background"], let fg = keys["foreground"],
              let accent = keys["accent"],
              let fgRGB = rgb(fg), let bgRGB = rgb(bg) else { return nil }

        // Omarchy's own precedence, from `omarchy-theme-color`'s resolve_theme_mode():
        // the `mode` key, then the legacy `theme_type` key, then the background's
        // luminance. (The `light.mode` marker file that sits between them there is dead
        // weight — no shipped theme uses it, and every one of them sets `mode`.)
        let isDark = mode(keys["mode"]) ?? mode(keys["theme_type"])
            ?? (bgRGB.red + bgRGB.green + bgRGB.blue <= 382)

        // `--border` and `--surface` have no Omarchy counterpart because they aren't
        // colours in a palette's sense — they're the alpha overlays of foreground on
        // background that separate a popover from the page. Synthesising them from the
        // foreground at the stock alphas keeps a themed page's depth identical to an
        // unthemed one's; taking `selection` or `lighter_background` instead would give
        // hairlines a hue of their own that no other Omarchy consumer shows.
        let overlay = { (alpha: String) in
            "rgba(\(fgRGB.red),\(fgRGB.green),\(fgRGB.blue),\(alpha))"
        }
        return ReaderPalette(bg: bg, fg: fg, muted: secondaryText(fg: fgRGB, bg: bgRGB),
                             accent: accent,
                             border: overlay(isDark ? "0.16" : "0.12"),
                             surface: overlay(isDark ? "0.08" : "0.05"),
                             isDark: isDark)
    }

    /// The flat `key = "value"` pairs of a colors.toml.
    ///
    /// A line-oriented reader rather than a TOML dependency: the file is a flat table of
    /// quoted scalars written by a shell script, and a parser for the language it *could*
    /// be would be more code than the app's whole theming path. Shelling out to
    /// `omarchy-theme-color` was the other option and is worse — it would make a GUI
    /// application fork a shell on every render, and fail differently on a box that has
    /// the themes but not the binary.
    private static func values(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Comments and table headers; the latter can't appear in a flat file but
            // skipping them costs nothing and keeps a section from becoming a key.
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.hasPrefix("\"") {
                let body = value.dropFirst()
                guard let end = body.firstIndex(of: "\"") else { continue }
                out[key] = String(body[..<end])
            } else if !value.isEmpty {
                // Tolerated for the legacy `theme_type`, which predates the quoting.
                out[key] = value.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// A light/dark declaration, or nil when the key is absent or says something else —
    /// so an unrecognised value falls through to the next signal rather than guessing.
    private static func mode(_ value: String?) -> Bool? {
        guard let value = value?.lowercased() else { return nil }
        if value == "dark" { return true }
        if value == "light" { return false }
        return nil
    }

    /// `#rgb` / `#rrggbb` to components. Omarchy writes six digits (in either case), but
    /// the three-digit form is valid CSS and costs one line to accept.
    private static func rgb(_ hex: String) -> (red: Int, green: Int, blue: Int)? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.dropFirst()
        let digits: [Character]
        switch body.count {
        case 3: digits = body.flatMap { [$0, $0] }
        case 6: digits = Array(body)
        default: return nil
        }
        var channels: [Int] = []
        channels.reserveCapacity(3)
        for i in stride(from: 0, to: 6, by: 2) {
            guard let value = Int(String(digits[i ... i + 1]), radix: 16) else { return nil }
            channels.append(value)
        }
        return (channels[0], channels[1], channels[2])
    }

    /// Secondary body text — bylines, feed hostnames, phrase counts — as the theme's
    /// foreground blended toward its background.
    ///
    /// Omarchy's `muted` key is deliberately not read. It is a **UI dim colour** — the
    /// tint of an inactive border or an unfocused chrome element — and not a text colour:
    /// on the shipped `last-horizon` it is literally the same value as `selection` and
    /// `dark_foreground` (`#584e51`). Mapping it onto `--muted` because the two share a
    /// name put a border colour behind running text and measured **2.45:1** against that
    /// theme's `#0c0b0c` background — a bit over half of WCAG AA, and the start page's
    /// hostname line was close to illegible for it.
    ///
    /// A blend has no such category problem, and it is what keeps secondary text legible
    /// on a theme nobody has seen. It starts 40% of the way to the background because that
    /// is where the stock palettes sit (`#9a9aa0` between `#f2f2f7` and `#1c1c1e`,
    /// `#6b6b70` between `#1c1c1e` and `#fafafa`), so a themed page dims secondary text by
    /// the same visual amount an unthemed one does. Being proportional it needs no
    /// light/dark branch: on a light theme the same blend walks down toward the paper.
    ///
    /// It then steps back toward the foreground until the result clears AA, because a user
    /// theme is arbitrary and some ship a foreground with little headroom to spend —
    /// Catppuccin Latte's `#4c4f69` on `#eff1f5` is only 7.06:1 to begin with, and a flat
    /// 40% blend would land secondary text at 2.80:1, no better than the bug this
    /// replaced. Stepping back costs contrast-rich themes nothing: every dark theme
    /// Omarchy ships keeps the full 40%.
    ///
    /// A theme whose foreground *itself* fails AA gets that foreground unchanged. No point
    /// between two colours beats both endpoints, so on such a theme secondary text stops
    /// being visibly secondary rather than becoming unreadable.
    private static func secondaryText(fg: (red: Int, green: Int, blue: Int),
                                      bg: (red: Int, green: Int, blue: Int)) -> String {
        // Contrast falls monotonically as the mix travels toward the background, so the
        // first step down from 40% that clears AA is also the most muted one that does.
        for percent in stride(from: 40, through: 1, by: -1) {
            let channel = { (from: Int, to: Int) in from + (to - from) * percent / 100 }
            let candidate = (red: channel(fg.red, bg.red),
                             green: channel(fg.green, bg.green),
                             blue: channel(fg.blue, bg.blue))
            if contrast(candidate, bg) >= 4.5 { return hexString(candidate) }
        }
        return hexString(fg)
    }

    /// Components back to `#rrggbb`, the form the rest of the palette is already in.
    private static func hexString(_ color: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
    }

    /// WCAG 2.1 contrast ratio, 1 (identical) to 21 (black on white).
    ///
    /// Duplicated in `ReaderPaletteTests` rather than shared: this is the host target, and
    /// `ReaderKit` — where a shared home would have to live — is Foundation-only and has
    /// no business knowing about accessibility maths it never performs.
    private static func contrast(_ a: (red: Int, green: Int, blue: Int),
                                 _ b: (red: Int, green: Int, blue: Int)) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG 2.1 relative luminance of an 8-bit sRGB triple.
    private static func luminance(_ color: (red: Int, green: Int, blue: Int)) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
}
