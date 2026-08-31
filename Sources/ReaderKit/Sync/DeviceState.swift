import Foundation

/// What one device publishes into the shared sync folder: its appearance settings and its
/// recents, plus the timestamps the merge orders them by.
///
/// One file per device, and **only that device ever writes it** — that's the whole reason
/// sync is files in a folder rather than one shared document. A folder synced by the
/// Nextcloud client (or iCloud Drive, or Syncthing) resolves collisions at file
/// granularity: two instances writing one `history.json` produce
/// `history (conflicted copy MacBook).json` and lose a write. With a single writer per
/// file there is never a collision to resolve, and merging is a pure fold over the files.
///
/// Pure Foundation, no platform types — `SyncFolder` does the I/O.
public struct DeviceState: Equatable, Sendable {
    /// Who wrote the file. The id names the file (stable across renames); the name is for
    /// the Sync sheet's device list.
    public struct Device: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The file format this code writes and reads. A file carrying anything else is
    /// skipped rather than guessed at — a future version's file is data we can't merge
    /// without dropping fields we don't know about.
    public static let version = 1

    public let device: Device
    /// When the file was last written. Status display only; merges never order by it,
    /// because a write happens on every sync whether or not anything changed.
    public let writtenAt: Double
    /// When settings were last changed on that device — what settings' last-writer-wins
    /// compares.
    public let settingsUpdatedAt: Double
    public let settings: ReaderSettings
    public let history: ReaderHistory

    public init(device: Device, writtenAt: Double, settingsUpdatedAt: Double,
                settings: ReaderSettings, history: ReaderHistory) {
        self.device = device
        self.writtenAt = writtenAt
        self.settingsUpdatedAt = settingsUpdatedAt
        self.settings = settings
        self.history = history
    }

    /// The file name a device's state is written under, so the writer of a file is known
    /// before it is read.
    public static func fileName(for deviceID: String) -> String { deviceID + ".json" }

    public var fileName: String { Self.fileName(for: device.id) }

    /// The file's bytes. Sorted keys so an unchanged state serializes byte-identically —
    /// a rewrite the sync client doesn't need to upload.
    public var json: String {
        let object: [String: Any] = [
            "v": Self.version,
            "device": ["id": device.id, "name": device.name],
            "writtenAt": writtenAt,
            "settingsUpdatedAt": settingsUpdatedAt,
            "settings": settings.jsonObject,
            "history": history.jsonObject,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tolerant decode: nil for anything that isn't a device file of a version we know —
    /// a half-written file, a stray JSON file the user dropped in the folder, a future
    /// format. A skipped peer costs nothing; a misread one would corrupt the merge.
    /// Settings and history decode with their own tolerance, so an unknown appearance
    /// value or a malformed row degrades to a default instead of dropping the device.
    public static func decode(_ value: Any?) -> DeviceState? {
        guard let object = value as? [String: Any],
              object["v"] as? Int == version,
              let device = object["device"] as? [String: Any],
              let id = device["id"] as? String, !id.isEmpty
        else { return nil }
        return DeviceState(
            device: Device(id: id, name: device["name"] as? String ?? id),
            writtenAt: object["writtenAt"] as? Double ?? 0,
            settingsUpdatedAt: object["settingsUpdatedAt"] as? Double ?? 0,
            settings: ReaderSettings.decode(object["settings"]),
            history: ReaderHistory.decode(object["history"]))
    }

    public static func fromJSON(_ string: String?) -> DeviceState? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return decode(try? JSONSerialization.jsonObject(with: data))
    }
}
