import Foundation

/// One sync cycle: read the other devices' files, fold them into the local state, write
/// back whatever changed, and publish this device's file.
///
/// Deliberately a plain struct rather than an actor: a cycle is a handful of small local
/// files (the sync client does the network part, out of process), the local state lives in
/// `UserDefaults` which is thread-safe, and an actor would only add hops. The host runs
/// cycles on one serial queue — never concurrently — so a stalled folder can't block the
/// UI, and applies the result on the main thread.
public struct SyncEngine: Sendable {
    public struct Result: Equatable, Sendable {
        /// The appearance settings changed under us — the visible page has to re-apply
        /// them.
        public var changedSettings = false
        /// The recents list changed — the start page has to be redrawn and the article
        /// cache pruned to match.
        public var changedHistory = false
        /// The other devices seen in the folder, for the Sync sheet.
        public var peers: [String] = []
    }

    private let folder: SyncFolder
    private let store: KeyValueStore
    private let device: DeviceState.Device
    private let clock: @Sendable () -> Double

    public init(folder: SyncFolder, store: KeyValueStore, device: DeviceState.Device,
                clock: @escaping @Sendable () -> Double = Timestamp.now) {
        self.folder = folder
        self.store = store
        self.device = device
        self.clock = clock
    }

    /// Runs a cycle. Throws only on a folder that can't be read or written — the local
    /// state is then left exactly as it was, so a folder that has gone away degrades to
    /// "no sync", never to lost recents.
    ///
    /// This device's own published file is not folded back in: local state is the source
    /// of truth for this device, and its file is a mirror of it.
    @discardableResult
    public func sync() throws -> Result {
        let peers = try folder.peers(excluding: device.id)

        let settings = ReaderStore.settings(store: store)
        let settingsUpdatedAt = ReaderStore.settingsUpdatedAt(store: store)
        let history = ReaderStore.history(store: store)
        let merged = SyncMerge.fold(settings: settings, settingsUpdatedAt: settingsUpdatedAt,
                                    history: history, peers: peers)

        var result = Result(peers: peers.map(\.device.name))
        if merged.settings != settings || merged.settingsUpdatedAt != settingsUpdatedAt {
            // Stamped with the winning device's time, not now: re-stamping would make this
            // device the newest writer of settings it didn't choose.
            ReaderStore.setSettings(merged.settings, store: store,
                                    at: merged.settingsUpdatedAt)
            result.changedSettings = merged.settings != settings
        }
        if merged.history != history {
            ReaderStore.setHistory(merged.history, store: store)
            result.changedHistory = true
        }

        let state = DeviceState(device: device, writtenAt: clock(),
                                settingsUpdatedAt: merged.settingsUpdatedAt,
                                settings: merged.settings, history: merged.history)
        if changed(from: folder.state(of: device.id), to: state) {
            try folder.write(state)
        }
        store.set(String(clock()), forKey: ReaderStore.Key.syncLastSuccess)
        return result
    }

    /// Everything but `writtenAt`: a cycle that learned nothing must not rewrite the file,
    /// or every foreground on every device would hand the sync client an upload.
    private func changed(from published: DeviceState?, to state: DeviceState) -> Bool {
        guard let published else { return true }
        return published.device != state.device
            || published.settingsUpdatedAt != state.settingsUpdatedAt
            || published.settings != state.settings
            || published.history != state.history
    }
}
