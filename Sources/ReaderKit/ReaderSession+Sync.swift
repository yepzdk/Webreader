import Foundation

extension ReaderSession {
    /// Sync's state changed — a folder chosen, a cycle landed, an error. Redraws whatever is
    /// showing it.
    ///
    /// Pushed into the page rather than re-rendering it: the settings page holds a half-typed
    /// feed address that has to survive someone setting sync up. The two values are also what
    /// the *next* render of that page will carry, which is how the Sync section appears at
    /// all — `SettingsPage` draws it only for a non-empty summary, so a host with no sync
    /// says nothing and gets no dead control.
    public func syncStatus(folder: String?, summary: String) -> [ReaderCommand] {
        syncFolderDisplayPath = folder
        syncSummary = summary
        guard pageState.isShowingSettings else { return [] }
        // A folder path is whatever the user named their folders; it takes the same escaping
        // route as feed titles rather than being spliced into the script by hand.
        let arguments: [Any] = [folder ?? NSNull(), summary]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [])
        else { return [] }
        return [.evaluate("window.readerSetSyncStatus && window.readerSetSyncStatus.apply(null, "
            + HTML.jsLiteral(String(decoding: data, as: UTF8.self)) + ")")]
    }

    /// Applies what a sync cycle merged in.
    ///
    /// Both halves update the visible page in place for the same reason: the start page holds
    /// a URL field, and re-rendering under someone mid-sentence throws their typing away. The
    /// page adopts what it is given without posting it back — that is the contract
    /// `readerApplySettings` carries, and breaking it would make this device the newest
    /// writer of settings it did not choose.
    public func applySync(_ result: SyncEngine.Result) -> [ReaderCommand] {
        guard isShowingReader || pageState.isShowingStartPage || pageState.isShowingSettings
        else { return [] }
        var commands: [ReaderCommand] = []
        if result.changedSettings {
            commands.append(.evaluate(
                "window.readerApplySettings && window.readerApplySettings(\(HTML.jsLiteral(ReaderStore.settings(store: store).json)))"))
        }
        guard result.changedHistory else { return commands }
        let history = ReaderStore.history(store: store)
        // The cache mirrors recents: a merge that dropped rows — a clear on another device —
        // has to drop their saved copies too.
        cache.prune(keeping: history.entries.map(\.url))
        let rows = history.entries.map { ["title": $0.title, "url": $0.url] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [])
        else { return commands }
        commands.append(.evaluate(
            "window.readerSetRecents && window.readerSetRecents(\(HTML.jsLiteral(String(decoding: data, as: UTF8.self))))"))
        return commands
    }
}
