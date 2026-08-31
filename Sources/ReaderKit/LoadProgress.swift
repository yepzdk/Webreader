import Foundation

/// Pure mapping from a web view's `estimatedProgress` (0...1) to what the top-edge progress
/// line should show. Kept free of AppKit so the floor/threshold logic is unit-testable; the
/// view animation itself lives in `HostDelegate`.
public enum LoadProgress: Equatable {
    /// No load in progress — the line is hidden.
    case hidden
    /// A load is underway; show the line at this fraction (0...1) of the window width.
    case loading(fraction: Double)
    /// The load just completed — fill to full, then fade out.
    case finished

    /// The smallest visible fraction, so a freshly-started load shows a sliver immediately
    /// rather than a zero-width (invisible) bar that only appears once progress climbs.
    public static let minimumVisibleFraction = 0.08
    /// Thickness, in px/pt, of both progress hairlines: the native page-load line and the
    /// reader page's scroll-progress line. A literal 1px reads as nothing on a HiDPI display;
    /// 2.5 registers as "loading". Exported so the CSS and every host read one value instead
    /// of a third platform adding a third hand-kept copy.
    public static let lineThickness: Double = 2.5
    /// What the loading cover says while a page is on its way (#24). One string, so the two
    /// hosts' native covers can't word it differently.
    public static let coverLabel = "Loading"
    /// Point size of that label. Matches `OfflineFallback`'s headline, the app's other
    /// full-window message, so the two read as the same kind of screen.
    public static let coverLabelSize: Double = 20
    /// Seconds for one pass of the highlight across the label. Slow enough to read as "still
    /// working" rather than as a flicker.
    public static let coverShimmerPeriod: Double = 1.6
    /// Width of the highlight ramp, as a multiple of the label's own width. The label is
    /// painted in `--muted` and the band that travels over it in `--fg`; both hosts derive
    /// their gradient from these two numbers, so neither can shimmer at its own speed.
    public static let coverShimmerSpread: Double = 1.25
    /// At/above this, treat the load as finished (WebKit reports 1.0 on completion).
    static let completeThreshold = 1.0

    public static func state(for estimatedProgress: Double) -> LoadProgress {
        // WebKit reports 0 when idle / at the very start of a navigation.
        if estimatedProgress <= 0 { return .hidden }
        if estimatedProgress >= completeThreshold { return .finished }
        // Floor the displayed fraction so early progress is visible, but never exceed the
        // real value's headroom — clamp into [floor, 1).
        return .loading(fraction: max(minimumVisibleFraction, min(estimatedProgress, 1)))
    }
}

/// Pure text for the generated app's About panel. Kept free of AppKit so it's
/// unit-testable.
