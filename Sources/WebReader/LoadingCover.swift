import Cocoa
import ReaderKit

/// The plain screen shown in place of a site while it loads (#24). Solid page background, the
/// word "Loading" in the secondary text colour, nothing else — the top-edge progress hairline
/// carries the rest.
///
/// Native rather than a generated page, for three reasons that all come from how the reader
/// pipeline works. A `loadHTMLString` cover would be a real back/forward entry wedged between
/// every pair of pages. `PageState.navigationStarted()` early-returns while a load of ours is
/// pending, so the real navigation's completion would be consumed as "our own page landed"
/// and extraction would never run — the shape of the bug 0.10.0 shipped. And the hairline
/// tracks the web view's own `estimatedProgress`, so a cover page's load would drive it to
/// full and fade it out before the real load even started.
///
/// Stacking between the web view and the hairline instead keeps the progress line untouched.
final class LoadingCover {
    /// How long the cover waits before revealing the page regardless. Extraction has no
    /// timeout and neither does WebKit's `didFinish`: a page that never settles (long-poll,
    /// an ad frame that keeps loading) must not leave "Loading" on screen for good.
    private static let patience: TimeInterval = 10

    private let view = NSView()
    private let label = NSTextField(labelWithString: LoadProgress.coverLabel)
    private var watchdog: Timer?

    /// Whether the cover is currently up. The show/hide calls are spread across every path
    /// that changes what's on screen, so they must be idempotent.
    private(set) var isVisible = false

    init(over webView: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        view.addSubview(label)
        // Above the web view, so it hides the site; the progress line is added in front of
        // everything (see `ProgressLine`), so it stays visible over this.
        container.addSubview(view, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// Covers the web view, painted for `theme` so the page it precedes doesn't arrive as a
    /// change of colour. `.auto` asks the system, which is the same question the page's
    /// `prefers-color-scheme` fallback would answer.
    func show(theme: ReaderSettings.Theme) {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = ReaderPalette.stock(for: theme, prefersDark: dark)
        view.layer?.backgroundColor = NSColor(css: palette.bg)?.cgColor
        label.textColor = NSColor(css: palette.muted) ?? .secondaryLabelColor
        view.isHidden = false
        isVisible = true
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.patience, repeats: false) {
            [weak self] _ in self?.hide()
        }
    }

    /// Reveals whatever is behind the cover. Called from every path that settles what's on
    /// screen — a rendered page of ours, an extraction that declined, a failed load, the
    /// reader toggle — and from the watchdog.
    func hide() {
        watchdog?.invalidate()
        watchdog = nil
        guard isVisible else { return }
        isVisible = false
        view.isHidden = true
    }
}

private extension NSColor {
    /// Parses the two colour spellings `ReaderPalette` uses: `#rrggbb` and `rgba(r,g,b,a)`.
    /// Both stock palettes and the Omarchy-derived ones are written in these forms, and a
    /// palette is data rather than a colour literal, so the host has to read it rather than
    /// hard-code its own copy.
    convenience init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                      green: CGFloat((value >> 8) & 0xff) / 255,
                      blue: CGFloat(value & 0xff) / 255,
                      alpha: 1)
            return
        }
        guard text.hasPrefix("rgba(") || text.hasPrefix("rgb(") else { return nil }
        let body = text.drop(while: { $0 != "(" }).dropFirst().dropLast()
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (3...4).contains(parts.count),
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2])
        else { return nil }
        let a = parts.count == 4 ? Double(parts[3]) ?? 1 : 1
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: CGFloat(a))
    }
}
