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
    /// What the loading cover can say while a page is on its way (#24). One list, so the two
    /// hosts cannot word it differently, and one is picked per load.
    ///
    /// All short and all in the same register: what the reader is actually doing to the page —
    /// stripping it back to type — rather than jokes. Deliberately no long ones. At 20pt a
    /// sentence risks clipping in a narrow window, and mixing a two-word message with a
    /// nine-word one makes the cover lurch between loads; "Putting the kettle on" carries the
    /// same idea as "grab a coffee, this will be a while" in a third of the width.
    public static let coverMessages = [
        "Collecting pixels",
        "Fetching your print",
        "Warming up the press",
        "Setting the type",
        "Clearing the clutter",
        "Sweeping up the ads",
        "Folding the paper",
        "Trimming the margins",
        "Inking the page",
        "Finding the article",
        "Putting the kettle on",
        "Straightening the columns",
        "Sharpening the serifs",
        "Chasing down the words",
        "Almost worth the wait",
    ]

    /// One message, for one appearance of the cover. Picked per load rather than per frame:
    /// a label that changed under you mid-wait would read as a glitch.
    public static func randomCoverMessage() -> String {
        // `coverMessages` is a non-empty literal and a test pins that, so the fallback is
        // unreachable — it is here so this never force-unwraps.
        coverMessages.randomElement() ?? "Loading"
    }
    /// Point size of that label. Matches `OfflineFallback`'s headline, the app's other
    /// full-window message, so the two read as the same kind of screen.
    public static let coverLabelSize: Double = 20
    /// Seconds for one pass of the highlight across the label. Slow enough to read as "still
    /// working" rather than as a flicker.
    public static let coverShimmerPeriod: Double = 1.6
    /// How long the cover tolerates a load making **no progress at all** before revealing the
    /// page anyway.
    ///
    /// Idle time, not total time. A fixed cap from the moment the cover went up fired
    /// mid-load on a slow connection and showed the site the cover exists to hide, which is
    /// the opposite of the point. A load that is still moving is a load worth waiting for,
    /// however long it takes; only silence means something is stuck — extraction that never
    /// calls back, or a frame that will never settle.
    public static let coverStallPatience: Double = 6
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
