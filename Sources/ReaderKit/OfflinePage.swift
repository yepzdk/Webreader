import Foundation

/// The page shown when a top-level load genuinely fails; its Try Again button posts
/// `readerRetry`, and the host retries the navigation that failed.
public enum OfflineFallback {
    /// The kind of failure, which selects the headline/message. Anything we don't
    /// specifically recognize falls to `.generic`.
    public enum Kind: Equatable {
        case offline       // no network connection at all
        case cannotReach   // DNS / host lookup failed
        case timedOut      // connection timed out
        case generic       // other load failure

        public var headline: String {
            switch self {
            case .offline: return "You're offline"
            case .cannotReach: return "Can't reach the site"
            case .timedOut: return "The connection timed out"
            case .generic: return "This page didn't load"
            }
        }

        /// The body line. `host` (when known) is woven in for the reachability cases.
        public func message(host: String?) -> String {
            let site = host.map { "“\($0)”" } ?? "the site"
            switch self {
            case .offline:
                return "Check your internet connection, then try again."
            case .cannotReach:
                return "We couldn't connect to \(site). It may be down, or your connection may be offline."
            case .timedOut:
                return "\(site) took too long to respond. Check your connection and try again."
            case .generic:
                return "Something went wrong loading \(site). Try again in a moment."
            }
        }
    }

    /// Maps a URL-loading error code to a `Kind`. Mirrors `NSURLError*` raw values so
    /// the classification stays pure (no Foundation error-domain matching needed).
    public static func classify(errorCode: Int) -> Kind {
        switch errorCode {
        case -1009: return .offline      // NSURLErrorNotConnectedToInternet
        case -1001: return .timedOut     // NSURLErrorTimedOut
        case -1003, // NSURLErrorCannotFindHost
             -1006: return .cannotReach  // NSURLErrorDNSLookupFailed
        default: return .generic
        }
    }

    /// Error codes that are NOT real load failures and must not trigger the fallback:
    /// a navigation the app itself cancelled (e.g. our policy/new-window handling) or a
    /// load interrupted by a policy decision. Showing an error page for these would
    /// replace good content with a spurious error.
    public static func isIgnorable(errorCode: Int) -> Bool {
        // NSURLErrorCancelled (-999) and WebKitErrorFrameLoadInterruptedByPolicyChange (102).
        errorCode == -999 || errorCode == 102
    }

    /// The fallback HTML. `appName` and `host` are HTML-escaped. `platform` selects the
    /// sans stack and defaults to macOS, so the AppKit host needs no argument.
    ///
    /// This page has no appearance settings — there is nothing to read here, so there is
    /// nothing to configure — which makes it permanently `auto`. A `palette` therefore
    /// always applies when one is given, replacing the light defaults and the
    /// `prefers-color-scheme` block both. Without one it follows the system exactly as
    /// before. Its palette is spelled out here rather than taken from `ReaderChrome`
    /// because it needs `--accent-fg` (the Try Again button) and no reading variables.
    public static func html(appName: String, host: String?, kind: Kind,
                            platform: Platform = .macOS,
                            palette: ReaderPalette? = nil) -> String {
        let headline = HTML.escape(kind.headline)
        let message = HTML.escape(kind.message(host: host))
        // The button label stays white on the accent in every palette: `ReaderPalette` has
        // no foreground-on-accent role, and inventing one from a colour literal the host
        // may have written as anything is guesswork the stock themes don't do either.
        let theme = palette.map {
            """
            :root {
              --bg: \($0.bg); --fg: \($0.fg); --muted: \($0.muted); --accent: \($0.accent);
              --accent-fg: #ffffff; --border: \($0.border);
              color-scheme: \($0.isDark ? "dark" : "light");
            }
            """
        } ?? """
        :root {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
          --accent-fg: #ffffff; --border: rgba(0,0,0,0.12);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
            --accent-fg: #ffffff; --border: rgba(255,255,255,0.16);
          }
        }
        """
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTML.escape(appName))</title>
        <style>
          \(ReaderChrome.indent(theme, by: 2))
          * { box-sizing: border-box; }
          html, body { height: 100%; margin: 0; }
          body {
            background: var(--bg);
            color: var(--fg);
            font: 15px/1.5 \(platform.sansStack);
            display: flex; align-items: center; justify-content: center;
            -webkit-font-smoothing: antialiased;
          }
          .card {
            text-align: center; padding: 24px; max-width: 30rem;
          }
          .icon { color: var(--muted); margin-bottom: 16px; }
          .icon svg { width: 44px; height: 44px; }
          h1 { font-size: 20px; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 8px; }
          p { color: var(--muted); margin: 0 auto 24px; max-width: 24rem; }
          .card button {
            font: inherit; font-weight: 500;
            color: var(--accent-fg); background: var(--accent);
            border: 0; border-radius: 6px; padding: 9px 18px; cursor: pointer;
            transition: opacity 160ms ease-out;
          }
          .card button:hover { opacity: 0.92; }
          .card button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
          @media (prefers-reduced-motion: reduce) { .card button { transition: none; } }
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 2))
        </style>
        </head>
        <body>
          \(ReaderChrome.indent(ReaderChrome.navHome(), by: 2))
          <div class="card">
            <div class="icon" aria-hidden="true">
              <!-- wifi-off, Lucide-style line icon, inherits currentColor -->
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
                   stroke-linecap="round" stroke-linejoin="round">
                <path d="M2 2l20 20"/>
                <path d="M8.5 16.5a5 5 0 0 1 7 0"/>
                <path d="M5 12.9a10 10 0 0 1 5.2-2.8"/>
                <path d="M19 12.9a10 10 0 0 0-3.6-2.5"/>
                <path d="M2 8.8a16 16 0 0 1 4.5-2.6"/>
                <path d="M22 8.8a16 16 0 0 0-9.4-2.7"/>
                <path d="M12 20h.01"/>
              </svg>
            </div>
            <h1>\(headline)</h1>
            <p>\(message)</p>
            <button onclick="window.webkit.messageHandlers.readerRetry.postMessage('retry')">Try Again</button>
          </div>
        </body>
        </html>
        """
    }

}

/// Minimal HTML-text escaping for values interpolated into the generated pages.
public enum HTML {
    /// JSON rendered as a JS expression for `evaluateJavaScript`. Two escapes
    /// `JSONSerialization` does not do: `</` would close the host page's `<script>` element,
    /// and U+2028/U+2029 terminate a JS statement even inside a string literal. Both are
    /// reachable from text the app didn't write (a feed title, an article title).
    public static func jsLiteral(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
