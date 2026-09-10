import UIKit
import ReaderWebKit

/// What sync needs to know about an iPhone or iPad.
///
/// Everything here follows from the sandbox. A folder chosen in the document picker is
/// security-scoped: the URL is inert until `startAccessingSecurityScopedResource()` says
/// otherwise, and a bookmark of it is only usable if it was *made* while that claim was
/// held — iOS has no `.withSecurityScope`, unlike macOS; the scope travels with an ordinary
/// bookmark instead. `ReaderSyncController` holds the claim for as long as sync uses the
/// folder and releases it when sync is turned off, which is the pairing this API expects.
struct IOSSyncPlatform: ReaderSyncPlatform {
    /// `UIDevice.name` is what the owner called the device, which is exactly what the other
    /// devices' summaries should say. On iOS 16 and later the system returns the model name
    /// ("iPhone") rather than the personalised one unless the app is entitled to it — a
    /// generic but honest answer, and never empty.
    var deviceName: String { UIDevice.current.name }

    var offSummary: String {
        "Settings and recents stay on this "
            + (UIDevice.current.userInterfaceIdiom == .pad ? "iPad." : "iPhone.")
    }

    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .minimalBookmark,
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    func beginAccess(to url: URL) -> Bool { url.startAccessingSecurityScopedResource() }

    func endAccess(to url: URL) { url.stopAccessingSecurityScopedResource() }
}
