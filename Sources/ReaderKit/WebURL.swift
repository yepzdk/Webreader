import Foundation

/// Pure URL helpers for the host's routing decisions, kept free of AppKit so they're
/// unit-testable.
public enum WebURL {
    /// The string to put on the pasteboard for "Copy Current URL", or nil if there's
    /// nothing to copy (no page loaded). Drives both the copy action and whether the
    /// menu item is enabled, so the two can't disagree.
    public static func urlToCopy(currentURL: URL?) -> String? {
        currentURL?.absoluteString
    }

    /// Whether `url` is an http/https URL we'd consider navigating to.
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether a content-triggered navigation stays in the web view. Web URLs do, and so
    /// does content the app itself loads (`about:`/`data:`/`blob:` — the start page,
    /// blank popups, generated downloads). Other schemes (`mailto:`, `msteams:`, …) can't
    /// render in the web view and are handed to the system instead.
    public static func loadsInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "data", "blob"].contains(scheme)
    }

    /// Parses clipboard text into an openable web URL, forgivingly (paste-and-go
    /// style): an absolute http(s) URL is used as-is; a bare host form like
    /// "example.com/article" is retried with https; anything else — prose, empty
    /// text, and non-web schemes (javascript:, file:, mailto:), which must never
    /// navigate — is nil.
    public static func clipboardURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return isWebURL(url) ? url : nil
        }
        // Bare host form: require a dot so ordinary words don't turn into lookups.
        guard trimmed.contains(".") else { return nil }
        guard let url = URL(string: "https://" + trimmed), url.host != nil else { return nil }
        return url
    }
}
