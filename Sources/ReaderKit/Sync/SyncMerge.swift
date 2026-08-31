import Foundation

/// Folds this device's state together with every other device's, deterministically and
/// without I/O — the rules live here so they're unit-tested rather than inferred from
/// behaviour in the field.
public enum SyncMerge {
    public struct Result: Equatable, Sendable {
        public var settings: ReaderSettings
        public var settingsUpdatedAt: Double
        public var history: ReaderHistory
    }

    /// Settings are last-writer-wins by `settingsUpdatedAt`: appearance is one coherent
    /// set of choices, so merging field by field would produce a look nobody picked. A tie
    /// keeps the local settings, and a tie between two peers keeps the first-sorting
    /// device id — two devices that wrote in the same second must not make every device
    /// disagree about which one won.
    ///
    /// History merges pairwise via `ReaderHistory.merging`, in device-id order for the
    /// same reason. That union is order-independent anyway (it keeps the newest read of
    /// each URL), so the sort only pins the tie-breaking.
    public static func fold(settings: ReaderSettings,
                            settingsUpdatedAt: Double,
                            history: ReaderHistory,
                            peers: [DeviceState]) -> Result {
        var result = Result(settings: settings, settingsUpdatedAt: settingsUpdatedAt,
                            history: history)
        for peer in peers.sorted(by: { $0.device.id < $1.device.id }) {
            if peer.settingsUpdatedAt > result.settingsUpdatedAt {
                result.settings = peer.settings
                result.settingsUpdatedAt = peer.settingsUpdatedAt
            }
            result.history = result.history.merging(peer.history)
        }
        return result
    }
}
