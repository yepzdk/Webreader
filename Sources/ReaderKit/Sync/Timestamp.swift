import Foundation

/// Every timestamp the reader stores — when an article was read, when history was cleared,
/// when settings last changed — is a whole number of **milliseconds** since 1970, carried as
/// a `Double` of seconds.
///
/// Not decoration: these values are compared for equality after a JSON round-trip. A cycle
/// only publishes when its state differs from the file it published last time, and
/// `settingsUpdatedAt` decides which device's appearance wins. Full `Double` precision
/// doesn't survive that trip identically on every platform — corelibs-Foundation's
/// `JSONSerialization` prints one significant digit fewer than Darwin's, so
/// `1788172957.1707573` came back as `1788172957.1707568` on Linux. Equality then fails on
/// values that never changed, and every device rewrites its file on every cycle: an upload
/// loop, forever, over nothing.
///
/// A millisecond grid needs 13 significant digits, well inside what both platforms print, and
/// nothing here needs finer resolution — it only has to order two reads on two devices.
/// Quantizing on the way in *and* on the way out means a hand-edited or sloppily serialized
/// value snaps back onto the grid instead of poisoning the comparison.
public enum Timestamp {
    /// Now, on the millisecond grid.
    public static func now() -> Double { stamp(Date().timeIntervalSince1970) }

    public static func stamp(_ time: Double) -> Double { (time * 1000).rounded() / 1000 }

    /// A timestamp out of a decoded JSON object: seconds as a number, or nil for anything
    /// else (missing, a string, garbage). Integers are accepted because that is what a
    /// whole-second value decodes as.
    public static func decode(_ value: Any?) -> Double? {
        if let seconds = value as? Double { return stamp(seconds) }
        if let seconds = value as? Int { return Double(seconds) }
        return nil
    }
}
