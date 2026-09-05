import Foundation

/// Where the per-device files live, as `SyncEngine` sees them: read the peers, read what
/// this device published last time, publish a new one. Three operations, and nothing about
/// folders or paths.
///
/// `SyncFolder` is the implementation every host with a filesystem uses. Android is why the
/// protocol exists: a folder chosen through the Storage Access Framework has no path, only
/// a document tree the Java side can open, and reaching back into Kotlin from Swift for
/// every read would mean JNI upcalls on a sync queue. `MemoryDeviceFiles` lets the host do
/// the I/O it is good at and hand the bytes over — the cycle then runs as a pure function,
/// which is also how the tests drive it.
public protocol DeviceFileStore: Sendable {
    /// Every other device's state, newest-written first. Unreadable, half-written, stray or
    /// future-format files are skipped, never fatal: one bad file must not stop sync.
    func peers(excluding deviceID: String) throws -> [DeviceState]
    /// What this device published last time, so a cycle that changed nothing doesn't
    /// rewrite the file and hand the sync client an upload with no news in it.
    func state(of deviceID: String) -> DeviceState?
    /// Publishes this device's state.
    func write(_ state: DeviceState) throws
}

/// Device files held in memory: the peers were read by someone else, and the write is
/// captured rather than performed.
///
/// For a host that owns its own I/O — Android's Storage Access Framework, or a test that
/// wants to assert what a cycle would publish without touching a disk. `written` is nil
/// when the cycle decided the published file was still current, which is the answer a
/// caller has to respect: writing anyway is exactly the needless upload
/// `SyncEngine.changed(from:to:)` exists to prevent.
public final class MemoryDeviceFiles: DeviceFileStore, @unchecked Sendable {
    private let states: [DeviceState]
    /// What the cycle asked to publish, or nil if it asked for nothing.
    public private(set) var written: DeviceState?

    /// `states` is every device file found, this device's own included — it is told apart
    /// by id, exactly as `SyncFolder` tells it apart by filename.
    public init(states: [DeviceState]) {
        self.states = states
    }

    public func peers(excluding deviceID: String) throws -> [DeviceState] {
        states.filter { $0.device.id != deviceID }.sorted { $0.writtenAt > $1.writtenAt }
    }

    public func state(of deviceID: String) -> DeviceState? {
        states.first { $0.device.id == deviceID }
    }

    public func write(_ state: DeviceState) throws {
        written = state
    }
}
