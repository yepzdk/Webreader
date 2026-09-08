import Foundation

/// Unwraps tracking/redirect URLs and strips tracking query parameters from
/// incoming links, so the app navigates straight to the destination without ever
/// contacting the tracking host (which may be blocked, e.g. by a Pi-hole).
///
/// Ported from https://github.com/yepzdk/url-cleaner with two deliberate
/// deviations for navigation safety: OAuth-style `redirect`/`redirect_uri`
/// parameters are never unwrapped (that would break sign-in links), and plain
/// (unencoded) URLs nested in a path are never unwrapped (that would break
/// Wayback Machine links). Pure — unit-tested.
public enum URLCleaner {
    /// Query parameters that redirectors put the destination in. Only unwrapped
    /// when the value is an absolute http(s) URL. Covers Google (`url`, `q`),
    /// Facebook `l.php` (`u`), LinkedIn and Outlook SafeLinks (`url`), and the
    /// long tail of `?target=`/`?dest=` style redirectors.
    private static let redirectParams: Set<String> =
        ["url", "u", "q", "link", "target", "dest", "destination"]

    /// Tracking query parameters to strip, as (exact names, name prefixes) —
    /// upstream's regex list flattened. Upstream also strips a bare `p`, which is
    /// skipped here: `?p=2` pagination is too common to break.
    private static let trackingParamNames: Set<String> = [
        "fbclid", "gclid", "yclid", "dclid", "twclid", "igshid", "icid",
        "ref", "ref_", "referer", "referrer", "source",
        "aff", "affiliate", "partner", "partnerid",
        "mkt_tok", "cmpid", "li_fat_id", "s_cid", "couponcode", "ssrc", "wt_zmc",
    ]
    private static let trackingParamPrefixes = [
        "utm_", "otm_", "mc_", "source_", "aff_", "hsa_", "oly_", "et_", "_hs",
    ]

    /// Cleans an incoming URL: repeatedly unwraps embedded destinations (bounded,
    /// for nested wrappers), then strips tracking parameters. Anything that can't
    /// be cleaned into a valid http(s) URL leaves the input unchanged — cleaning
    /// must never turn a working URL into a broken one.
    public static func clean(_ url: URL) -> URL {
        var current = url
        // Unwrap until stable; 3 passes covers tracking-in-tracking without
        // giving a pathological URL an endless loop.
        for _ in 0..<3 {
            guard let unwrapped = unwrapDestination(of: current),
                  unwrapped != current else { break }
            current = unwrapped
        }
        return stripTrackingParams(from: current) ?? current
    }

    /// The key two URLs share when they are the same article.
    ///
    /// Deliberately not `clean`, and never used to navigate. `clean` answers "where should
    /// this go?", and its first rule is that it must not turn a working URL into a broken
    /// one — so it keeps the host exactly as written, because plenty of sites answer on
    /// `www.` and nowhere else. This answers a different question: "have I already read
    /// this?", where `dr.dk/x` and `www.dr.dk/x` are the same piece of writing.
    ///
    /// The bug it exists for: a feed offers `https://dr.dk/…`, the site redirects to
    /// `https://www.dr.dk/…`, recents record where you landed — and the article you just
    /// finished was still the first thing offered at the end of it, because the two strings
    /// are not equal. Scheme, a leading `www.`, host case, a trailing slash and a fragment
    /// all come off; the cleaned query stays, since `?p=2` is a different page.
    public static func identity(_ url: URL) -> String {
        let cleaned = clean(url)
        guard var components = URLComponents(url: cleaned, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return cleaned.absoluteString }
        components.scheme = nil
        components.fragment = nil
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // A port only where it is not the default one: two articles on the same host cannot
        // differ by :443, and a local server on :8080 is genuinely somewhere else.
        let port = components.port.flatMap { $0 == 80 || $0 == 443 ? nil : ":\($0)" } ?? ""
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return bare + port + path + query
    }

    // MARK: - Unwrapping

    /// One unwrapping pass: the embedded destination if `url` looks like a
    /// redirector, nil otherwise.
    private static func unwrapDestination(of url: URL) -> URL? {
        if let fromQuery = destinationFromQuery(url) { return fromQuery }
        if let fromPath = encodedDestinationInPath(url) { return fromPath }
        if let postmark = postmarkDestination(url) { return postmark }
        return nil
    }

    /// A known redirect parameter whose value is an absolute http(s) URL.
    private static func destinationFromQuery(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        for item in items where redirectParams.contains(item.name.lowercased()) {
            if let value = item.value, let dest = URL(string: value),
               WebURL.isWebURL(dest), dest.host != nil {
                return dest
            }
        }
        return nil
    }

    /// A percent-encoded absolute URL embedded in the path, e.g. TLDR's
    /// `…/CL0/https:%2F%2Fwww.figma.com%2Fblog%2F…%3Futm_source=x/1/0100…`.
    /// The destination's own slashes are still encoded (%2F), so it ends at the
    /// first LITERAL `/` after the marker. Only encoded embeds are unwrapped —
    /// a plain nested `https://` is left alone (Wayback Machine links).
    private static func encodedDestinationInPath(_ url: URL) -> URL? {
        // Work on the raw absolute string so the encoding is still visible.
        let raw = url.absoluteString
        let lower = raw.lowercased()
        // The scheme may have its colon encoded too (https%3A%2F%2F).
        let markers = ["https:%2f%2f", "http:%2f%2f", "https%3a%2f%2f", "http%3a%2f%2f"]
        guard let (markerRange, _) = markers
            .compactMap({ marker in lower.range(of: marker).map { ($0, marker) } })
            .min(by: { $0.0.lowerBound < $1.0.lowerBound })
        else { return nil }
        // Never treat the URL's own scheme as an embed.
        guard markerRange.lowerBound != lower.startIndex else { return nil }

        let tail = String(raw[markerRange.lowerBound...])
        let encoded = tail.split(separator: "/", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0]
        guard let decoded = String(encoded).removingPercentEncoding,
              let dest = URL(string: decoded),
              WebURL.isWebURL(dest), dest.host != nil
        else { return nil }
        return dest
    }

    /// Postmark email tracking: `track.pstmrk.it/{2s,3s,4s}/dest.tld/path/TOKEN` —
    /// the destination is unencoded and schemeless, followed by a long tracking
    /// segment (30+ chars of [a-z0-9-], or 10+ digits). Upstream's exact rule.
    private static func postmarkDestination(_ url: URL) -> URL? {
        guard url.host?.lowercased() == "track.pstmrk.it" else { return nil }
        let raw = url.absoluteString
        let prefixes = ["track.pstmrk.it/3s/", "track.pstmrk.it/2s/",
                        "track.pstmrk.it/4s/", "track.pstmrk.it/"]
        for prefix in prefixes {
            guard let range = raw.range(of: prefix) else { continue }
            var tail = String(raw[range.upperBound...])
            if let match = tail.range(
                of: #"^([^/]+(?:/[^/]+)*?)(?:/[a-z0-9-]{30,}|/\d{10,})"#,
                options: [.regularExpression, .caseInsensitive]) {
                // Group 1 is the destination; re-derive it by trimming the
                // tracking segment the alternation matched at the end.
                let matched = String(tail[match])
                if let cut = matched.range(of: #"(?:/[a-z0-9-]{30,}|/\d{10,})$"#,
                                           options: [.regularExpression, .caseInsensitive]) {
                    tail = String(matched[..<cut.lowerBound])
                } else {
                    tail = matched
                }
            }
            let decoded = tail.removingPercentEncoding ?? tail
            let withScheme = decoded.hasPrefix("http://") || decoded.hasPrefix("https://")
                ? decoded : "https://" + decoded
            if let dest = URL(string: withScheme),
               WebURL.isWebURL(dest), dest.host != nil {
                return dest
            }
            return nil
        }
        return nil
    }

    // MARK: - Tracking parameters

    /// Whether a query parameter name is a known tracker.
    static func isTrackingParam(_ name: String) -> Bool {
        let lower = name.lowercased()
        return trackingParamNames.contains(lower)
            || trackingParamPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Removes tracking parameters, preserving everything else (order, fragment).
    /// Nil when the URL can't be decomposed — the caller keeps the original.
    private static func stripTrackingParams(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        guard let items = components.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { !isTrackingParam($0.name) }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}
