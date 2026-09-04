import Cocoa
import ReaderKit
import WebKit

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
    private let view = NSView()
    private let label = ShimmerLabel()
    private var watchdog: Timer?
    /// Watches the load so the watchdog can measure *silence* rather than elapsed time.
    private var progressObserver: NSKeyValueObservation?

    /// Whether the cover is currently up. The show/hide calls are spread across every path
    /// that changes what's on screen, so they must be idempotent.
    private(set) var isVisible = false

    init(over webView: WKWebView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
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
        // The cover keeps its own eye on the load rather than being fed progress by the
        // delegate: whether it may come down is its business, and `ProgressLine` watching the
        // same key path is no obstacle.
        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) {
            [weak self] _, _ in self?.noteProgress()
        }
    }

    /// The load moved, so it is not stuck: start the silence over.
    private func noteProgress() {
        guard isVisible else { return }
        armWatchdog()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: LoadProgress.coverStallPatience,
                                        repeats: false) { [weak self] _ in self?.hide() }
    }

    /// Covers the web view, painted for `theme` so the page it precedes doesn't arrive as a
    /// change of colour. `.auto` asks the system, which is the same question the page's
    /// `prefers-color-scheme` fallback would answer.
    func show(theme: ReaderSettings.Theme) {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = ReaderPalette.stock(for: theme, prefersDark: dark)
        view.layer?.backgroundColor = NSColor(css: palette.bg)?.cgColor
        label.setText(LoadProgress.randomCoverMessage())
        label.paint(base: NSColor(css: palette.muted) ?? .secondaryLabelColor,
                    highlight: NSColor(css: palette.fg) ?? .labelColor)
        view.isHidden = false
        label.startShimmer()
        isVisible = true
        armWatchdog()
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
        // Nothing to look at, so stop spending frames on it.
        label.stopShimmer()
    }
}

/// The cover's label: the word painted in the secondary text colour with a brighter band
/// travelling across it, which is what says "still working" on a screen that is otherwise
/// completely still.
///
/// A `CAGradientLayer` masked by a `CATextLayer`, rather than a `CATextLayer` in a solid
/// colour: the gradient has to be clipped to the glyphs, and masking is the only way to get
/// that without drawing text by hand. Sweeping the gradient's `locations` past both ends
/// works because a `CAGradientLayer` pads with its end colours — so the word is fully
/// painted in the base colour at every moment of the cycle and only the highlight moves.
/// (The CSS equivalent, `background-clip: text`, goes transparent past the ends instead and
/// has to tile the gradient to avoid it.)
private final class ShimmerLabel: NSView {
    private static let animationKey = "readerShimmer"

    private let gradient = CAGradientLayer()
    private let glyphs = CATextLayer()
    private var size: NSSize = .zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = Self.locations(at: 0)
        glyphs.alignmentMode = .center
        gradient.mask = glyphs
        applyScale()
    }

    /// Sets the message. The messages differ in width, so the measured size is the view's
    /// intrinsic one and Auto Layout is told to ask again.
    func setText(_ text: String) {
        // The mask only needs coverage, so the colour is irrelevant as long as it is opaque.
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(LoadProgress.coverLabelSize),
                                     weight: .semibold),
            // -0.01em, the same tightening the offline page's headline uses.
            .kern: -CGFloat(LoadProgress.coverLabelSize) * 0.01,
            .foregroundColor: NSColor.black,
        ])
        glyphs.string = attributed
        size = attributed.size()
        size.width.round(.up)
        size.height.round(.up)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: NSSize { size }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        glyphs.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? 2
        gradient.contentsScale = scale
        glyphs.contentsScale = scale
    }

    /// Repaints for a theme. `base` is the resting colour of the whole word, `highlight` the
    /// band that crosses it.
    func paint(base: NSColor, highlight: NSColor) {
        gradient.colors = [base.cgColor, highlight.cgColor, base.cgColor]
    }

    func startShimmer() {
        // Someone who has asked the system for less movement gets the word, held still.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            gradient.removeAnimation(forKey: Self.animationKey)
            gradient.locations = Self.locations(at: 0)
            return
        }
        guard gradient.animation(forKey: Self.animationKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = Self.locations(at: 0)
        sweep.toValue = Self.locations(at: 1 + LoadProgress.coverShimmerSpread)
        sweep.duration = LoadProgress.coverShimmerPeriod
        sweep.repeatCount = .greatestFiniteMagnitude
        gradient.add(sweep, forKey: Self.animationKey)
    }

    func stopShimmer() {
        gradient.removeAnimation(forKey: Self.animationKey)
    }

    /// The three stops at a point in the cycle. `progress` runs from 0 (highlight entirely
    /// off the left edge) to `1 + spread` (entirely off the right), so one cycle is one pass.
    private static func locations(at progress: Double) -> [NSNumber] {
        let spread = LoadProgress.coverShimmerSpread
        return [progress - spread, progress - spread / 2, progress].map { NSNumber(value: $0) }
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
