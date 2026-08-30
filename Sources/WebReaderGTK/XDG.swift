import Foundation

/// Where this app's files live on a freedesktop system, per the XDG Base Directory spec.
///
/// Resolved from the environment by hand rather than through `FileManager.urls(for:in:)`:
/// that returns the bare base directory with no application component, and the macOS host's
/// habit of appending the bundle id would give `~/.cache/dk.yepz.webreader`, which is not
/// what anything else under `~/.cache` looks like. The component is the command name,
/// `webreader`.
enum XDG {
    /// `$XDG_CACHE_HOME/<app>`, else `~/.cache/<app>`. Created if missing — the article
    /// cache writes into it.
    static func cacheDirectory(_ app: String) -> URL {
        created(base("XDG_CACHE_HOME", fallback: ".cache").appendingPathComponent(app, isDirectory: true))
    }

    /// `$XDG_CONFIG_HOME/<app>`, else `~/.config/<app>`. Created if missing — `FileStore`
    /// writes into it.
    static func configDirectory(_ app: String) -> URL {
        created(base("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent(app, isDirectory: true))
    }

    /// `$XDG_STATE_HOME`, else `~/.local/state`. Deliberately not created and carries no app
    /// component: we only read it, to find the current Omarchy theme another program owns.
    static func stateDirectory() -> URL {
        base("XDG_STATE_HOME", fallback: ".local/state")
    }

    /// The spec says a value that is not an absolute path must be ignored as if it were
    /// unset — so an empty or relative `$XDG_*_HOME` falls back rather than producing a
    /// directory relative to whatever the launcher's working directory happened to be.
    private static func base(_ variable: String, fallback: String) -> URL {
        if let raw = ProcessInfo.processInfo.environment[variable], raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(fallback, isDirectory: true)
    }

    private static func created(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
