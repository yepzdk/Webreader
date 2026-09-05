import Cocoa
import ReaderKit
import ReaderWebKit

/// What sync needs to know about a Mac.
///
/// The app is not sandboxed, so a folder the user picked in an open panel is simply a
/// folder: nothing to claim, and a plain bookmark is enough to find it again after a rename
/// or a move. The sandboxed counterpart is `IOSSyncPlatform`, which has to claim the folder
/// and make security-scoped bookmarks while holding that claim.
struct MacSyncPlatform: ReaderSyncPlatform {
    var deviceName: String { Host.current().localizedName ?? "Mac" }

    var offSummary: String { "Settings and recents stay on this Mac." }

    func bookmark(for url: URL) -> Data? { try? url.bookmarkData() }

    func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    func beginAccess(to url: URL) -> Bool { true }

    func endAccess(to url: URL) {}
}
