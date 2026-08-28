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
    /// missing the four colours a palette needs).
    static func current() -> ReaderPalette? {
        let file = XDG.stateDirectory()
            .appendingPathComponent("omarchy", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("theme", isDirectory: true)
            .appendingPathComponent("colors.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let keys = values(in: text)

        // The four roles Omarchy actually names. Anything less is not a palette we can
        // render from, so we decline rather than mix half a theme into the stock one.
        guard let bg = keys["background"], let fg = keys["foreground"],
              let accent = keys["accent"], let muted = keys["muted"],
              let fgRGB = rgb(fg) else { return nil }

        // Omarchy's own precedence, from `omarchy-theme-color`'s resolve_theme_mode():
        // the `mode` key, then the legacy `theme_type` key, then the background's
        // luminance. (The `light.mode` marker file that sits between them there is dead
        // weight — no shipped theme uses it, and every one of them sets `mode`.)
        let isDark: Bool
        if let declared = mode(keys["mode"]) ?? mode(keys["theme_type"]) {
            isDark = declared
        } else if let bgRGB = rgb(bg) {
            isDark = bgRGB.red + bgRGB.green + bgRGB.blue <= 382
        } else {
            return nil
        }

        // `--border` and `--surface` have no Omarchy counterpart because they aren't
        // colours in a palette's sense — they're the alpha overlays of foreground on
        // background that separate a popover from the page. Synthesising them from the
        // foreground at the stock alphas keeps a themed page's depth identical to an
        // unthemed one's; taking `selection` or `lighter_background` instead would give
        // hairlines a hue of their own that no other Omarchy consumer shows.
        let overlay = { (alpha: String) in
            "rgba(\(fgRGB.red),\(fgRGB.green),\(fgRGB.blue),\(alpha))"
        }
        return ReaderPalette(bg: bg, fg: fg, muted: muted, accent: accent,
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
}
