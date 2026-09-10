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

    /// Parses what another app *shared* into an openable web URL.
    ///
    /// Deliberately more forgiving than `clipboardURL`, and deliberately a separate rule.
    /// Pasting is ambiguous — someone who pasted prose into a URL field probably mis-pasted,
    /// so guessing at a link inside it would be wrong, which is why `clipboardURL` refuses
    /// anything with a space in it. Sharing is not ambiguous: an app that puts "Some headline
    /// https://example.com/x" in an ACTION_SEND extra is handing over that link, and on
    /// Android that shape is the common case rather than the exception.
    ///
    /// An explicit scheme is required when the text is more than the link alone. A bare host
    /// found in the middle of a sentence is a word that happens to contain a dot far more
    /// often than it is an address.
    public static func sharedURL(from raw: String?) -> URL? {
        if let url = clipboardURL(from: raw) { return url }
        guard let raw else { return nil }
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            // Leading punctuation comes off first: a link the sentence wrapped in brackets or
            // quotes is still the link that was handed over, and the scheme test below has to
            // be able to see the scheme.
            let candidate = token.drop(while: { openingPunctuation.contains($0) })
            let lowered = candidate.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { continue }
            if let url = clipboardURL(from: withoutSentencePunctuation(candidate)) { return url }
        }
        return nil
    }

    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}"]
    private static let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "\u{201D}", "\u{2019}"]
    private static let bracketPairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// Drops what a sentence leaves on a link it ends with, and nothing more.
    ///
    /// A closing bracket is the sentence's only when the URL did not open it itself.
    /// "…/wiki/Foo_(bar)" is an ordinary address, and trimming its bracket quietly opens a
    /// different page that usually does not exist.
    private static func withoutSentencePunctuation(_ token: Substring) -> String {
        var end = token.endIndex
        while end > token.startIndex {
            let last = token.index(before: end)
            let character = token[last]
            if let opener = bracketPairs[character] {
                // One pass, counting both: `count(where:)` is Swift 6, and the Mac app is
                // built on an older toolchain on purpose (see .github/workflows/ci.yml).
                var openers = 0
                var closers = 0
                for scanned in token[token.startIndex..<last] {
                    if scanned == opener { openers += 1 }
                    else if scanned == character { closers += 1 }
                }
                guard openers <= closers else { break }
            } else if !closingPunctuation.contains(character) {
                break
            }
            end = last
        }
        return String(token[token.startIndex..<end])
    }
}
