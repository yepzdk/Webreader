import Cocoa
import ReaderKit

/// Runs sync cycles and tells the app what changed under it.
///
/// Sync is a folder the user picks — typically inside their Nextcloud folder or iCloud
/// Drive — that WebReader exchanges one small JSON file per device through. Nothing here
/// talks to a server: whatever already syncs that folder does the moving.
///
/// Cycles are triggered by the app coming forward, the start page being shown, a local
/// change (debounced), and the folder changing on disk; a 30-second poll while frontmost
/// is the backstop for the one case the folder watcher misses — a sync client rewriting a
/// file's contents in place rather than replacing it. A cycle never runs concurrently with
/// itself: a trigger arriving mid-cycle sets `again` and runs once the current one lands.
@MainActor
final class SyncController {
    private let store: KeyValueStore
    /// Called on the main thread after a cycle changed local state.
    private let onChange: (SyncEngine.Result) -> Void
    /// Called whenever the status changes, so an open sheet can redraw.
    var onStatusChange: (() -> Void)?

    /// Cycles run here — file I/O on a folder that may live on a slow or stalled mount
    /// must never block the UI. Serial, so cycles can't interleave.
    private let queue = DispatchQueue(label: "dk.yepz.webreader.sync", qos: .utility)

    private var root: URL?
    private var device: DeviceState.Device
    /// One watcher per watched path: the device-file folder (files appearing, vanishing or
    /// being replaced) and each peer's file (a client rewriting one in place, which a
    /// directory watch never sees).
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    private var running = false
    private var again = false
    private var peers: [String] = []
    private var lastError: String?

    init(store: KeyValueStore, onChange: @escaping (SyncEngine.Result) -> Void) {
        self.store = store
        self.onChange = onChange
        // The device id names the one file this installation writes, so it has to outlive
        // a rename of the Mac; the name is display only.
        let id = store.string(forKey: ReaderStore.Key.syncDeviceID) ?? ""
        if id.isEmpty { store.set(UUID().uuidString, forKey: ReaderStore.Key.syncDeviceID) }
        device = DeviceState.Device(
            id: store.string(forKey: ReaderStore.Key.syncDeviceID) ?? UUID().uuidString,
            name: Host.current().localizedName ?? "Mac")
        root = resolveFolder()
    }

    // MARK: - What the UI shows

    var isOn: Bool { root != nil }

    /// The chosen folder, `~`-abbreviated, or nil when sync is off. Display only — the
    /// bookmark is what sync actually resolves.
    var folderDisplayPath: String? {
        store.string(forKey: ReaderStore.Key.syncFolderPath)
            .map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    /// One line of state: the error if there is one, otherwise when it last synced and who
    /// else it can see. The Sync sheet and the settings page both show this string, so the
    /// two can't describe sync differently.
    var summary: String {
        if let lastError { return lastError }
        guard isOn else { return "Settings and recents stay on this Mac." }
        guard let last = Double(store.string(forKey: ReaderStore.Key.syncLastSuccess) ?? "")
            .map(Date.init(timeIntervalSince1970:)) else { return "Waiting for the first sync…" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let synced = "Last synced " + formatter.localizedString(for: last, relativeTo: Date())
        switch peers.count {
        case 0: return synced + " · no other devices yet"
        case 1: return synced + " · with " + peers[0]
        default: return synced + " · with \(peers.count) other devices"
        }
    }

    /// True while the last cycle's error is the thing `summary` is reporting.
    var hasError: Bool { lastError != nil }

    /// Picks up where the last run left off: start watching and sync once.
    func start() {
        guard root != nil else { return }
        startWatching()
        syncNow()
    }

    /// Turns sync on for `url` (what the user picked in the open panel).
    ///
    /// The folder is remembered as a bookmark so a rename or a move doesn't silently stop
    /// sync; the path is kept alongside for display only. This app is not sandboxed, so
    /// the bookmark is a plain one — security-scoped bookmarks require the sandbox
    /// entitlement, and that arrives with the iOS target (#6).
    func choose(_ url: URL) {
        record(url)
        root = url
        lastError = nil
        peers = []
        startWatching()
        syncNow()
    }

    /// Turns sync off, and takes this device's file with it — a folder that keeps
    /// advertising a device that no longer syncs is worse than one that doesn't.
    func turnOff() {
        if let root {
            let folder = SyncFolder(root: root)
            try? FileManager.default.removeItem(
                at: folder.directory.appendingPathComponent(DeviceState.fileName(for: device.id)))
        }
        debounce?.cancel()
        stopWatching()
        root = nil
        peers = []
        lastError = nil
        store.set(nil, forKey: ReaderStore.Key.syncFolder)
        store.set(nil, forKey: ReaderStore.Key.syncFolderPath)
        store.set(nil, forKey: ReaderStore.Key.syncLastSuccess)
        onStatusChange?()
    }

    // MARK: - Triggers

    /// Coming forward is the catch-all trigger: it covers everything that changed while
    /// the watchers were down (the folder offline, the app launched after the other device
    /// wrote).
    func applicationDidBecomeActive() {
        guard root != nil else { return }
        syncNow()
    }

    /// A local write (settings, recents, a clear) that the other devices should see.
    /// Debounced: stepping the font size four times is one publish.
    func localStateChanged() {
        guard root != nil else { return }
        scheduleSync(after: 2)
    }

    func startPageShown() {
        guard root != nil else { return }
        syncNow()
    }

    func syncNow() {
        guard let root else { return }
        guard !running else { again = true; return }
        running = true
        let engine = SyncEngine(folder: SyncFolder(root: root), store: store, device: device)
        queue.async { [weak self] in
            var result: SyncEngine.Result?
            var message: String?
            do {
                result = try engine.sync()
            } catch let error as SyncError {
                message = error.message
            } catch {
                message = error.localizedDescription
            }
            Task { @MainActor [weak self] in self?.finish(result: result, error: message) }
        }
    }

    private func finish(result: SyncEngine.Result?, error: String?) {
        running = false
        if let result {
            lastError = nil
            peers = result.peers
            if result.changedSettings || result.changedHistory { onChange(result) }
        } else {
            lastError = error
            // A cycle fails when the folder has moved, been renamed, or been deleted and
            // recreated by a sync client. `resolveFolder` handles all three, so re-resolve
            // and keep the folder configured: every later trigger retries, and sync picks
            // itself up without the user having to choose the folder again.
            root = resolveFolder() ?? root
        }
        // Re-armed after every cycle: the folder may have gained a device to watch, lost
        // one, or come back after being unreachable, and a file that was replaced leaves
        // its watcher holding a descriptor that points at nothing.
        startWatching()
        onStatusChange?()
        if again {
            again = false
            syncNow()
        }
    }

    private func scheduleSync(after seconds: TimeInterval) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Folder

    /// Where the sync folder is now, or nil when sync was never turned on.
    ///
    /// Two things move under us, and both have to keep working without the user picking
    /// the folder again:
    ///
    /// - the folder is renamed or moved — the bookmark follows it, and the new path is
    ///   re-recorded;
    /// - the folder is deleted and recreated at the same path — which is exactly what a
    ///   sync client does when the folder changes upstream. The bookmark is dead (the
    ///   inode is gone), so the recorded path takes over and a fresh bookmark is made.
    ///
    /// A folder that isn't there at all still resolves to its recorded path, with the
    /// reason in the sheet: every trigger then retries, and sync resumes by itself the
    /// moment the folder comes back.
    private func resolveFolder() -> URL? {
        let manager = FileManager.default
        let recorded = store.string(forKey: ReaderStore.Key.syncFolderPath)
        if let encoded = store.string(forKey: ReaderStore.Key.syncFolder),
           let data = Data(base64Encoded: encoded) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               manager.fileExists(atPath: url.path) {
                if stale || url.path != recorded { record(url) }
                return url
            }
        }
        guard let recorded else { return nil }
        let url = URL(fileURLWithPath: recorded, isDirectory: true)
        guard manager.fileExists(atPath: recorded) else {
            lastError = SyncError.folderUnreadable(recorded).message
            return url
        }
        record(url)
        return url
    }

    private func record(_ url: URL) {
        if let data = try? url.bookmarkData() {
            store.set(data.base64EncodedString(), forKey: ReaderStore.Key.syncFolder)
        }
        store.set(url.path, forKey: ReaderStore.Key.syncFolderPath)
    }

    // MARK: - Watching

    /// Watches the device-file folder and every peer's file in it, so another device's
    /// change shows up without waiting for anything.
    ///
    /// Both halves are needed: the folder catches files appearing, vanishing or being
    /// replaced (a sync client downloads to a temp name and renames), while a watch on each
    /// file catches a client that rewrites one in place — a directory watch never sees
    /// that. Our own file is left unwatched; only this instance writes it.
    ///
    /// The `WebReader` subfolder is created up front — there is nothing to watch otherwise,
    /// and this instance is about to write into it — but never the chosen folder itself: if
    /// that has gone, sync stays visibly broken rather than quietly publishing into a
    /// folder nothing syncs.
    private func startWatching() {
        stopWatching()
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return }
        let directory = SyncFolder(root: root).directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watch(directory.path)
        let own = DeviceState.fileName(for: device.id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name != own && name.hasSuffix(".json") && !name.hasPrefix(".") {
            watch(directory.appendingPathComponent(name).path)
        }
    }

    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A download arrives as a burst of events; one cycle covers the lot. The set of
            // watched files is re-armed after every cycle, so a file that was replaced or
            // removed (its descriptor now pointing at nothing) is picked up there.
            self.scheduleSync(after: 1)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[path] = source
    }

    private func stopWatching() {
        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
    }
}
