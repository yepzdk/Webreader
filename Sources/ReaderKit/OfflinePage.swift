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
        /// The load succeeded and answered with something that is not a web page — a feed, a
        /// PDF, a download. Distinct from the four above because nothing failed and trying
        /// again would answer exactly the same way.
        case notAPage

        public var headline: String {
            switch self {
            case .offline: return "You're offline"
            case .cannotReach: return "Can't reach the site"
            case .timedOut: return "The connection timed out"
            case .generic: return "This page didn't load"
            case .notAPage: return "There's nothing to read here"
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
            case .notAPage:
                return "\(site) answered with a file rather than a web page — a feed, or something to download."
            }
        }

        /// Whether asking again could plausibly answer differently. It could not for a file
        /// the reader cannot display, and a button that is certain to fail is worse than no
        /// button: the way out of this page is Home, which its chrome carries.
        public var retryable: Bool {
            self != .notAPage
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
        case 100: return .notAPage       // WebKitErrorCannotShowMIMEType
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
        // This page spells its own palette rather than taking `ReaderChrome.themeCSS`, so it
        // has to define the safe-area variables its chrome offsets read. Left out, every
        // `var(--safe-*)` here resolves to nothing, the declaration around it is invalid, and
        // the page loses the insets that keep Home clear of a notch.
        let safeArea = ReaderChrome.safeAreaCSS(platform: platform)
        let theme = palette.map {
            """
            :root {
              --bg: \($0.bg); --fg: \($0.fg); --muted: \($0.muted); --accent: \($0.accent);
              --accent-fg: #ffffff; --border: \($0.border);
              color-scheme: \($0.isDark ? "dark" : "light");
            \(safeArea)
            }
            """
        } ?? """
        :root {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
          --accent-fg: #ffffff; --border: rgba(0,0,0,0.12);
        \(safeArea)
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
            --accent-fg: #ffffff; --border: rgba(255,255,255,0.16);
          }
        }
        """
        // Only `.notAPage` can be a feed — the other four kinds mean the address never
        // answered at all — so only that page carries the offer, script included. The
        // gate is the kind itself rather than `retryable`, because what decides this is
        // whether the response could be a feed, not whether asking again is worthwhile.
        let offerButton = kind == .notAPage ? feedOfferButton : ""
        let offerScript = kind == .notAPage ? feedOfferScript : ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        \(ReaderChrome.viewportMeta)
        <meta name="color-scheme" content="light dark">
        <title>\(HTML.escape(appName))</title>
        \(ReaderChrome.transportScript(platform: platform))
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
            text-align: center; max-width: 30rem;
            /* The card is centred in the viewport, so it needs no safe-area padding of its
               own on the block axis — but a landscape notch does eat into the inline one. */
            padding: 24px max(24px, var(--safe-left)) 24px
                        max(24px, var(--safe-right));
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
          /* Touch: the one action on the page reaches the 44px floor. */
          @media (pointer: coarse) {
            .card button {
              padding: 12px 22px; min-height: \(ReaderChrome.touchTarget)px;
            }
          }
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 2))
          \(ReaderChrome.indent(ReaderChrome.chromeCSS(platform: platform), by: 2))
        </style>
        </head>
        <body>
          \(ReaderChrome.indent(ReaderChrome.chrome(nav: ReaderChrome.navHome()), by: 2))
          <div class="card">
            <div class="icon" aria-hidden="true">
              \(kind.retryable ? wifiOffIcon : notAPageIcon)
            </div>
            <h1>\(headline)</h1>
            <p>\(message)</p>
        \(kind.retryable
            ? "    <button onclick=\"readerPost('readerRetry', 'retry')\">Try Again</button>\n"
            : offerButton)  </div>
        \(offerScript)</body>
        </html>
        """
    }

    /// wifi-off, Lucide-style line icon, inherits currentColor.
    private static let wifiOffIcon = """
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
    """

    /// file-x, from the same set: a document the reader cannot open, not a lost connection.
    private static let notAPageIcon = """
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
                   stroke-linecap="round" stroke-linejoin="round">
                <path d="M15 3v5a1 1 0 0 0 1 1h5"/>
                <path d="M18 21H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h9l5 5v11a2 2 0 0 1-2 2z"/>
                <path d="M9.5 13.5l5 5"/>
                <path d="M14.5 13.5l-5 5"/>
              </svg>
    """

    /// The offer's button, which ships hidden and empty because the host may never make the
    /// offer: confirming an address is a feed means fetching and parsing it, and it may turn
    /// out to be a PDF or a download instead. It sits in the markup rather than being built
    /// by the script so that there is exactly one of it — a second offer relabels this
    /// button instead of stacking another beside it — and it wears no class of its own
    /// because `.card button` is already the page's primary action, which this is.
    private static let feedOfferButton =
        "    <button id=\"readerFeedOffer\" hidden></button>\n"

    /// Reveals the offer when the host calls `readerOfferFeed({title, url})`, and posts the
    /// same `readerAddSource` message the settings page's add-source form posts, so a feed
    /// accepted here arrives through the one path that already knows what to do with it.
    ///
    /// The label is assembled as text, never markup — the same rule the suggestion rows
    /// follow, and for the same reason: the title comes from a stranger's feed. A payload
    /// missing either field is dropped rather than shown as a half-written offer.
    private static let feedOfferScript = """
      <script>
      (function () {
        var offer = document.getElementById('readerFeedOffer');
        offer.addEventListener('click', function () {
          window.readerPost('readerAddSource', offer.dataset.url);
        });
        window.readerOfferFeed = function (feed) {
          if (!feed || !feed.title || !feed.url) { return; }
          offer.dataset.url = feed.url;
          offer.textContent = 'Add “' + feed.title + '” to suggested articles';
          offer.hidden = false;
        };
      })();
      </script>

    """

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

    /// A Swift string as a quoted JS string literal, script-safe.
    ///
    /// `jsLiteral` takes an already-serialised expression (a JSON object, a number) and only
    /// makes it safe to sit inside `<script>`; it does not quote. Interpolating a bare string
    /// through it emits raw markup into the middle of a statement, so anything that is a
    /// *value* rather than an expression comes through here.
    public static func jsString(_ value: String) -> String {
        // JSONSerialization encodes containers only, so the value rides in a one-element
        // array and the brackets come back off — this way the quoting and escaping are
        // Foundation's rather than hand-rolled.
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []) else {
            return "\"\""
        }
        let array = String(decoding: data, as: UTF8.self)
        return jsLiteral(String(array.dropFirst().dropLast()))
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
