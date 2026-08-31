import Foundation

/// Why a sync cycle couldn't run. `message` is what the Sync sheet shows — plain
/// language, no error codes, because every one of these is something the user can fix.
public enum SyncError: Error, Equatable, Sendable {
    /// The chosen folder is gone, renamed beyond what the bookmark tracks, or not
    /// readable.
    case folderUnreadable(String)
    case writeFailed(String)

    public var message: String {
        switch self {
        case .folderUnreadable(let path):
            return "Can't read \(path). Choose the sync folder again."
        case .writeFailed(let reason):
            return "Couldn't write to the sync folder: \(reason)"
        }
    }
}

/// The shared folder devices exchange their state through: `<chosen folder>/WebReader/`,
/// one `<deviceID>.json` per device.
///
/// This instance writes exactly one file and reads the rest. Whatever syncs the folder
/// (the Nextcloud desktop client, iCloud Drive, Syncthing, a USB stick) never sees two
/// writers on one path and so never produces a conflicted copy.
///
/// File I/O with an injected directory, like `ArticleCache` — tests point it at a temp
/// folder.
public struct SyncFolder: Sendable {
    /// The subfolder created inside whatever the user picked, so pointing WebReader at a
    /// whole Nextcloud folder doesn't scatter files across it.
    public static let folderName = "WebReader"

    /// What the user picked.
    public let root: URL

    public init(root: URL) { self.root = root }

    public var directory: URL {
        root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Every other device's state, newest-written first. Unreadable, half-written, stray
    /// or future-format files are skipped, never fatal: one bad file must not stop sync.
    ///
    /// A missing `WebReader` subfolder is normal (nobody has synced into this folder yet)
    /// and yields no peers; a missing *root* is an error, because that's the folder the
    /// user chose having gone away.
    public func peers(excluding deviceID: String) throws -> [DeviceState] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            guard manager.fileExists(atPath: root.path) else {
                throw SyncError.folderUnreadable(root.path)
            }
            return []
        }
        let own = DeviceState.fileName(for: deviceID)
        var peers: [DeviceState] = []
        for name in names where name != own {
            // An iCloud Drive file that hasn't been downloaded shows up as a hidden
            // `.name.json.icloud` placeholder: ask for it and pick it up next cycle.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                requestDownload(of: String(name.dropFirst().dropLast(".icloud".count)))
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let url = directory.appendingPathComponent(name)
            if !isDownloaded(url) {
                requestDownload(of: name)
                continue
            }
            if let state = read(url) { peers.append(state) }
        }
        return peers.sorted { $0.writtenAt > $1.writtenAt }
    }

    /// What this device published last time, so a sync that changed nothing doesn't
    /// rewrite the file and hand the sync client an upload with no news in it.
    public func state(of deviceID: String) -> DeviceState? {
        read(directory.appendingPathComponent(DeviceState.fileName(for: deviceID)))
    }

    /// Publishes this device's state, creating the `WebReader` subfolder on first use.
    ///
    /// The folder the user chose is NOT created: if it has been deleted or moved away, the
    /// write has to fail. Recreating it would publish into a path nothing syncs — a folder
    /// that looks like it's working while the devices silently drift apart.
    ///
    /// Atomic: the bytes land in a temp file in the same folder and are renamed over the
    /// destination, so a sync client can never pick up (and upload) a half-written file.
    public func write(_ state: DeviceState) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SyncError.folderUnreadable(root.path)
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            throw SyncError.writeFailed((error as NSError).localizedDescription)
        }
        let url = directory.appendingPathComponent(state.fileName)
        let data = Data(state.json.utf8)
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let failure = writeError ?? coordinationError {
            throw SyncError.writeFailed((failure as NSError).localizedDescription)
        }
    }

    // MARK: - Reading

    /// A coordinated read, so a file being materialized by iCloud or replaced by the sync
    /// client isn't read mid-write. nil for a missing, unreadable or non-device file.
    private func read(_ url: URL) -> DeviceState? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return DeviceState.decode(object)
    }

    /// False only for an iCloud item that exists as metadata but has no local bytes yet.
    /// Ordinary files (the Nextcloud client's, Syncthing's) have no downloading status and
    /// are always readable.
    private func isDownloaded(_ url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    private func requestDownload(of name: String) {
        try? FileManager.default.startDownloadingUbiquitousItem(
            at: directory.appendingPathComponent(name))
    }
}
