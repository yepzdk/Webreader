import Foundation

/// The page chrome shared by the reader page and the handler-only start page: the theme
/// palette, the "Aa" appearance popover, and the recents list.
///
/// Both pages are standalone documents built as strings, and both need these pieces
/// byte-for-byte — the start page exists so you can pick a recent article and set up type
/// before opening anything (#91). Keeping them here rather than duplicating means a tweak
/// to a swatch or a row can't drift between the two.
///
/// Pure string composition, matching how every built-in page in this project is built (no
/// templating engine). Fragments are emitted left-aligned; callers place them with
/// `indent(_:by:)` so the generated HTML stays tidy.
enum ReaderChrome {
    /// Re-indents a fragment's continuation lines by `spaces`, leaving the first line alone
    /// (it's already positioned by the interpolation site). Blank lines stay blank.
    static func indent(_ fragment: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return fragment
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { i, line in
                if i == 0 || line.isEmpty { return String(line) }
                return pad + line
            }
            .joined(separator: "\n")
    }

    /// The `data-theme` and `data-quotes` attributes for `<html>`. Each is absent at its
    /// default (`auto` follows the system; bordered quotes are the stylesheet's baseline), so
    /// the stock page is attribute-free.
    static func themeAttribute(_ settings: ReaderSettings) -> String {
        (settings.theme == .auto ? "" : " data-theme=\"\(settings.theme.rawValue)\"")
            + (settings.quoteStyle == .bordered ? "" : " data-quotes=\"\(settings.quoteStyle.rawValue)\"")
    }

    /// The palette custom properties: light defaults, the dark media query, and the four
    /// explicit `[data-theme]` palettes. The attribute selectors deliberately come last so
    /// they outrank both the defaults and the media query.
    ///
    /// `platform` selects the reading font stack and defaults to macOS, so the AppKit host
    /// needs no argument; the Linux host passes `.linux`.
    static func themeCSS(_ settings: ReaderSettings, platform: Platform = .macOS) -> String {
        """
        :root {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
          --border: rgba(0,0,0,0.12); --surface: rgba(0,0,0,0.05);
          --reader-size: \(settings.fontSize)px;
          --reader-leading: \(settings.lineHeight.css);
          --reader-width: \(settings.width.css);
          --reader-font: \(settings.fontFamily.css(on: platform));
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
            --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          }
        }
        /* Explicit themes pin a palette; the attribute selector outranks both the
           light defaults and the dark media query above. */
        :root[data-theme="light"] {
          --bg: #fafafa; --fg: #1c1c1e; --muted: #6b6b70; --accent: #2563eb;
          --border: rgba(0,0,0,0.12); --surface: rgba(0,0,0,0.05);
          color-scheme: light;
        }
        :root[data-theme="sepia"] {
          --bg: #f4ecd8; --fg: #3d3225; --muted: #6f6049; --accent: #2563eb;
          --border: rgba(61,50,37,0.18); --surface: rgba(61,50,37,0.07);
          color-scheme: light;
        }
        :root[data-theme="dark"] {
          --bg: #1c1c1e; --fg: #f2f2f7; --muted: #9a9aa0; --accent: #3b82f6;
          --border: rgba(255,255,255,0.16); --surface: rgba(255,255,255,0.08);
          color-scheme: dark;
        }
        :root[data-theme="black"] {
          --bg: #000000; --fg: #f2f2f7; --muted: #98989e; --accent: #3b82f6;
          --border: rgba(255,255,255,0.18); --surface: rgba(255,255,255,0.10);
          color-scheme: dark;
        }
        """
    }

    /// CSS for the chrome controls: the button row, both popovers, the appearance segments
    /// and swatches, and the recents rows. Chrome UI, so it keeps the platform's sans stack
    /// and fixed sizes regardless of the reading settings.
    static func controlsCSS(platform: Platform = .macOS) -> String {
        let sans = platform.sansStack
        let serif = platform.serifStack
        return """
        .reader-controls {
          position: fixed; top: 14px; right: 14px; z-index: 10;
          display: flex; gap: 6px;
          font-family: \(sans); font-size: 12px; line-height: 1.3;
        }
        /* Each button owns the popover anchored under it. */
        .reader-control { position: relative; }
        #readerAa, #readerRecentsBtn, #readerHiddenBtn {
          padding: 4px 10px; font-family: inherit; font-size: 14px;
          color: var(--muted); background: var(--bg);
          border: 1px solid var(--border); border-radius: 6px; cursor: pointer;
        }
        #readerAa:hover, #readerAa[aria-expanded="true"],
        #readerRecentsBtn:hover, #readerRecentsBtn[aria-expanded="true"],
        #readerHiddenBtn:hover, #readerHiddenBtn[aria-expanded="true"] { color: var(--fg); }
        /* The icon buttons match the "Aa" button's box; the SVGs inherit currentColor. */
        #readerRecentsBtn, #readerHiddenBtn, #readerMoreBtn, #readerLessBtn {
          display: flex; align-items: center; padding: 5px 9px;
        }
        #readerRecentsBtn svg, #readerHiddenBtn svg,
        #readerMoreBtn svg, #readerLessBtn svg { display: block; }
        /* Rating buttons: same box as the other icon controls. Pressed is the accent, the one
           place in the chrome where a control is "on" rather than merely open. */
        #readerMoreBtn, #readerLessBtn {
          padding: 5px 9px; font-family: inherit;
          color: var(--muted); background: var(--bg);
          border: 1px solid var(--border); border-radius: 6px; cursor: pointer;
        }
        #readerMoreBtn:hover, #readerLessBtn:hover { color: var(--fg); }
        #readerMoreBtn[aria-pressed="true"], #readerLessBtn[aria-pressed="true"] {
          color: #fff; background: var(--accent); border-color: var(--accent);
        }
        /* How many blocks this article lost. Inverted neutrals — black on white in light,
           white on black in dark, brown on cream in sepia — never the accent. */
        #readerHiddenBtn { position: relative; }
        .badge {
          position: absolute; top: -6px; right: -6px; min-width: 16px; height: 16px;
          padding: 0 4px; border-radius: 8px; background: var(--fg); color: var(--bg);
          font-size: 10px; font-weight: 600; line-height: 16px; text-align: center;
        }
        .badge[hidden] { display: none; }
        #readerPanel, #readerRecents, #readerHidden {
          position: absolute; top: calc(100% + 8px); right: 0; width: 240px;
          padding: 12px; background: var(--bg);
          border: 1px solid var(--border); border-radius: 8px;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12);
          display: flex; flex-direction: column; gap: 10px;
        }
        #readerPanel[hidden], #readerRecents[hidden], #readerHidden[hidden] { display: none; }
        /* Recents: a plain list of titles. Padding is on the rows, so the panel itself
           sheds its gap and lets a long list scroll instead of running off-screen.
           Right-anchored like the Aa panel: the controls sit at the window's right edge,
           so the panel has to hang leftward to stay on screen. `max-width` keeps it from
           running off the LEFT edge on a narrow window. */
        #readerRecents, #readerHidden {
          width: 280px; max-width: calc(100vw - 28px);
          padding: 6px; gap: 0; max-height: 60vh; overflow-y: auto;
        }
        .recent {
          display: block; width: 100%; padding: 7px 8px; border: 0; border-radius: 5px;
          background: transparent; cursor: pointer; text-align: left;
          font-family: inherit; font-size: 12px; color: var(--fg);
        }
        .recent:hover { background: var(--surface); }
        .recent-title {
          display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        .recent-host { display: block; margin-top: 2px; font-size: 11px; color: var(--muted); }
        .recent-empty, .phrase-empty { margin: 0; padding: 7px 8px; color: var(--muted); }
        /* Hidden-text rows: the phrase and a remove control. Built by the page script from
           the phrase list via textContent — no phrase ever becomes markup. */
        .phrase {
          display: flex; align-items: center; gap: 6px; padding: 4px 4px 4px 8px;
          border-radius: 5px; font-size: 12px; color: var(--fg);
        }
        .phrase:hover { background: var(--surface); }
        .phrase-text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .phrase-remove {
          display: flex; padding: 4px; border: 0; border-radius: 4px; background: transparent;
          color: var(--muted); cursor: pointer;
        }
        .phrase-remove:hover { color: var(--fg); background: var(--border); }
        .phrase-remove svg { display: block; }
        .phrase-count { flex: none; font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; }
        /* Phrases that hit this article are listed first; the rest follow under a rule. */
        .phrase-group {
          margin: 6px 6px 2px; padding: 0 2px; font-size: 10px; font-weight: 600;
          letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted);
        }
        .phrase-group.rest { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--border); }
        /* Clearing history lives next to the history itself — Restore Defaults is for
           presentation settings and deliberately leaves user data alone. */
        #readerClear {
          margin: 4px 6px 2px; padding: 6px 8px; border: 0; border-top: 1px solid var(--border);
          border-radius: 0; background: transparent; cursor: pointer; text-align: left;
          font-family: inherit; font-size: 11px; color: var(--muted);
        }
        #readerClear:hover { color: var(--fg); }
        /* Popover headings — the popovers are opened from unlabelled icon buttons, so
           each one names itself once opened. */
        .panel-title {
          margin: 0; padding: 2px 2px 8px; border-bottom: 1px solid var(--border);
          font-size: 11px; font-weight: 600; letter-spacing: 0.04em;
          text-transform: uppercase; color: var(--muted);
        }
        /* The list panels put padding on their rows, so their headings carry their own. */
        #readerRecents .panel-title, #readerHidden .panel-title { margin: 2px 6px 4px; padding: 2px 2px 8px; }
        .seg { display: flex; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
        .seg button {
          flex: 1; padding: 7px 0; border: 0; background: transparent; cursor: pointer;
          font-family: inherit; font-size: 12px; color: var(--muted);
        }
        .seg button + button { border-left: 1px solid var(--border); }
        .seg button[aria-pressed="true"] { background: var(--surface); color: var(--fg); }
        .seg button:disabled { opacity: 0.4; cursor: default; }
        .seg button[data-value="serif"] { font-family: \(serif); }
        .a-small { font-size: 12px; }
        .a-large { font-size: 17px; }
        .themes { display: flex; justify-content: space-between; padding: 2px; }
        .swatch {
          width: 26px; height: 26px; border-radius: 50%; cursor: pointer;
          border: 1px solid var(--border); padding: 0;
        }
        .swatch[aria-pressed="true"] { box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px var(--accent); }
        .swatch-auto { background: linear-gradient(135deg, #fafafa 50%, #1c1c1e 50%); }
        .swatch-light { background: #fafafa; }
        .swatch-sepia { background: #f4ecd8; }
        .swatch-dark { background: #1c1c1e; }
        .swatch-black { background: #000000; }
        """
    }

    /// A transient confirmation, bottom-centre: what just happened and what it will do. Used
    /// by the start page's block and more/less controls, where the effect is either invisible
    /// (a stored preference) or destructive-looking (a row vanishing).
    ///
    /// One live region reused for every message, so rapid clicks replace rather than stack.
    static func toastCSS(platform: Platform = .macOS) -> String {
        """
        #readerToast {
          position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%) translateY(6px);
          z-index: 20; max-width: calc(100vw - 32px);
          padding: 8px 14px; border: 1px solid var(--border); border-radius: 6px;
          background: var(--bg); color: var(--fg);
          font-family: \(platform.sansStack); font-size: 12px; line-height: 1.4;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12);
          opacity: 0; pointer-events: none;
          transition: opacity 140ms ease, transform 140ms ease;
        }
        #readerToast[data-shown="true"] { opacity: 1; transform: translateX(-50%) translateY(0); }
        @media (prefers-reduced-motion: reduce) {
          #readerToast { transition: none; transform: translateX(-50%); }
          #readerToast[data-shown="true"] { transform: translateX(-50%); }
        }
        """
    }

    static func toastMarkup() -> String {
        "<div id=\"readerToast\" role=\"status\" aria-live=\"polite\"></div>"
    }

    /// Defines `window.readerToast(text)`. Text only — the message is set with `textContent`,
    /// so a host name from a feed can never become markup.
    static func toastScript() -> String {
        """
        (function () {
          var node = document.getElementById('readerToast');
          var timer = null;
          window.readerToast = function (text) {
            if (!node || !text) { return; }
            node.textContent = text;
            node.setAttribute('data-shown', 'true');
            if (timer) { clearTimeout(timer); }
            timer = setTimeout(function () { node.removeAttribute('data-shown'); }, 2600);
          };
        })();
        """
    }

    /// The reading-progress line: a hairline along the top edge that fills as the article
    /// scrolls, so a chromeless reader still answers "how much is left?" (#93).
    ///
    /// Thickness is `LoadProgress.lineThickness`, the same constant the native page-load
    /// line reads, so a new host can't drift. The two lines are deliberately *different
    /// colours*: the native load line is accent-coloured, this one is `var(--fg)`, because
    /// an accent hairline parked at 30% reads as a stuck load. `z-index` sits below
    /// `.reader-controls` (10) so an open popover is never crossed by a colored line.
    static func progressCSS() -> String {
        """
        #readerProgress {
          position: fixed; top: 0; left: 0; width: 100%; height: \(LoadProgress.lineThickness)px; z-index: 9;
          /* Foreground, not accent: the native page-load line is accent-colored, and a
             blue hairline sitting still at 30% reads as a stuck load. */
          background: var(--fg);
          /* scaleX from the left rather than animating width: composites on the GPU, so a
             fast scroll doesn't force layout on every frame. */
          transform-origin: left center; transform: scaleX(0);
        }
        #readerProgress[hidden] { display: none; }
        """
    }

    /// The progress line's element. Starts hidden — the script shows it only once it knows
    /// the article actually scrolls, so a short piece never displays a permanently full bar.
    /// `aria-hidden` because a scroll fraction is decorative; the article text is the content.
    static func progressBar() -> String {
        "<div id=\"readerProgress\" hidden aria-hidden=\"true\"></div>"
    }

    /// Drives the reading-progress line from scroll position. A separate fragment from
    /// `controlsScript` because only the reader page installs it — it registers
    /// `window.readerOnLayoutChange`, which the appearance popover calls after changing type
    /// metrics (font size, column width and leading all change how far there is to scroll).
    ///
    /// Emitted after `controlsScript` so that hook is in place before the first `apply()`.
    static func progressScript() -> String {
        """
        (function () {
          var bar = document.getElementById('readerProgress');
          var root = document.documentElement;
          var ticking = false;

          function measure() {
            var max = root.scrollHeight - root.clientHeight;
            // Nothing to scroll (a short article, or a window taller than the text): hide
            // rather than show a full bar, which would read as "you're at the end".
            if (max <= 0) {
              bar.hidden = true;
              return;
            }
            bar.hidden = false;
            var fraction = root.scrollTop / max;
            fraction = Math.min(1, Math.max(0, fraction));
            bar.style.transform = 'scaleX(' + fraction + ')';
          }
          // Coalesce to one write per frame: a trackpad flick fires scroll far faster than
          // the display refreshes.
          function schedule() {
            if (ticking) { return; }
            ticking = true;
            window.requestAnimationFrame(function () {
              ticking = false;
              measure();
            });
          }

          // Passive: this never calls preventDefault, so it must not block scrolling.
          window.addEventListener('scroll', schedule, { passive: true });
          window.addEventListener('resize', schedule);
          // Measure directly rather than via schedule(): requestAnimationFrame doesn't fire
          // while a window is occluded or offscreen, and the bar's initial state (crucially,
          // whether it's hidden at all) must not wait for a frame that may never come.
          window.readerOnLayoutChange = measure;
          measure();
        })();
        """
    }

    /// One recents row per entry, newest first — built here rather than by the page script
    /// so titles and URLs (other sites' content) run through the same escaping as the rest
    /// of the page. The URL lives in a data attribute; the host re-validates it before
    /// navigating.
    static func recentsRows(_ history: ReaderHistory) -> String {
        history.entries.map { entry in
            let host = URL(string: entry.url)?.host ?? ""
            let hostLine = host.isEmpty ? ""
                : "<span class=\"recent-host\">\(HTML.escape(host))</span>"
            return "<button class=\"recent\" data-url=\"\(HTML.escape(entry.url))\">"
                + "<span class=\"recent-title\">\(HTML.escape(entry.title))</span>"
                + "\(hostLine)</button>"
        }.joined(separator: "\n")
    }

    /// The recents popover's contents: the heading, the rows, and the clear action — or the
    /// empty state. The clear action only appears when there's something to clear.
    static func recentsBody(_ history: ReaderHistory) -> String {
        let heading = "<h2 class=\"panel-title\" id=\"readerRecentsTitle\">Recent articles</h2>"
        guard !history.entries.isEmpty else {
            return heading + "\n<p class=\"recent-empty\">No recent articles</p>"
        }
        return heading + "\n" + recentsRows(history)
            + "\n<button id=\"readerClear\">Clear history</button>"
    }

    /// The chrome markup: the recents button with its popover, the hidden-text button with
    /// its (script-filled) list, then the "Aa" button with the appearance popover. All carry
    /// hover tooltips and name their own panel, since the buttons themselves are unlabelled.
    /// `rating` adds the like/dislike pair — the reader page passes the current article's
    /// rating (nil = unrated); the start page omits it, since there is no article to rate.
    static func controls(history: ReaderHistory,
                         showsRating: Bool = false,
                         rating: TopicPreferences.Rating? = nil) -> String {
        let current = rating
        let ratingControls = !showsRating ? "" : """
        <div class="reader-control">
            <button id="readerMoreBtn" aria-label="More articles like this"
                    title="More like this" aria-pressed="\(current == .more)">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                   stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M7 10v12"/>
                <path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/>
              </svg>
            </button>
          </div>
          <div class="reader-control">
            <button id="readerLessBtn" aria-label="Fewer articles like this"
                    title="Less like this" aria-pressed="\(current == .less)">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                   stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M17 14V2"/>
                <path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/>
              </svg>
            </button>
          </div>
        """
        return """
        <div class="reader-controls">
          \(ratingControls)
          <div class="reader-control">
            <button id="readerRecentsBtn" aria-label="Recent articles"
                    title="Recent articles" aria-haspopup="true"
                    aria-expanded="false" aria-controls="readerRecents">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                   stroke-width="2" stroke-linecap="round" aria-hidden="true">
                <path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>
              </svg>
            </button>
            <div id="readerRecents" hidden aria-labelledby="readerRecentsTitle">
              \(indent(recentsBody(history), by: 6))
            </div>
          </div>
          <div class="reader-control">
            <button id="readerHiddenBtn" aria-label="Hidden text"
                    title="Hidden text" aria-haspopup="true"
                    aria-expanded="false" aria-controls="readerHidden">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                   stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/>
                <path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/>
                <path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/>
                <path d="M2 2l20 20"/>
              </svg>
              <span id="readerHiddenCount" class="badge" hidden aria-hidden="true"></span>
            </button>
            <div id="readerHidden" hidden aria-labelledby="readerHiddenTitle">
              <h2 class="panel-title" id="readerHiddenTitle">Hidden text</h2>
              <div id="readerHiddenList"></div>
            </div>
          </div>
          <div class="reader-control">
            <button id="readerAa" aria-label="Reader appearance"
                    title="Text &amp; appearance" aria-haspopup="true"
                    aria-expanded="false" aria-controls="readerPanel">Aa</button>
            <div id="readerPanel" hidden aria-labelledby="readerPanelTitle">
              <h2 class="panel-title" id="readerPanelTitle">Text &amp; appearance</h2>
              <div class="seg" role="group" aria-label="Font size">
                <button data-step="-1" aria-label="Decrease font size"
                        title="Smaller text"><span class="a-small">A</span></button>
                <button data-step="1" aria-label="Increase font size"
                        title="Larger text"><span class="a-large">A</span></button>
              </div>
              <div class="seg" role="group" aria-label="Font style">
                <button data-key="fontFamily" data-value="serif">Serif</button>
                <button data-key="fontFamily" data-value="sans">Sans</button>
              </div>
              <div class="seg" role="group" aria-label="Column width">
                <button data-key="width" data-value="narrow">Narrow</button>
                <button data-key="width" data-value="normal">Normal</button>
                <button data-key="width" data-value="wide">Wide</button>
              </div>
              <div class="seg" role="group" aria-label="Line height">
                <button data-key="lineHeight" data-value="compact">Compact</button>
                <button data-key="lineHeight" data-value="normal">Normal</button>
                <button data-key="lineHeight" data-value="relaxed">Relaxed</button>
              </div>
              <div class="seg" role="group" aria-label="Quotes">
                <button data-key="quoteStyle" data-value="bordered">Bordered</button>
                <button data-key="quoteStyle" data-value="italic">Italic</button>
              </div>
              <div class="themes" role="group" aria-label="Theme">
                <button class="swatch swatch-auto" data-key="theme" data-value="auto" aria-label="Auto theme" title="Auto"></button>
                <button class="swatch swatch-light" data-key="theme" data-value="light" aria-label="Light theme" title="Light"></button>
                <button class="swatch swatch-sepia" data-key="theme" data-value="sepia" aria-label="Sepia theme" title="Sepia"></button>
                <button class="swatch swatch-dark" data-key="theme" data-value="dark" aria-label="Dark theme" title="Dark"></button>
                <button class="swatch swatch-black" data-key="theme" data-value="black" aria-label="Black theme" title="Black"></button>
              </div>
            </div>
          </div>
        </div>
        """
    }

    /// The chrome script: applies the appearance settings live, persists them via
    /// `readerSettings`, opens a recents row via `readerOpen`, clears the list via
    /// `readerClear`, and drops a hidden phrase via `readerUnhide`. Shared verbatim so both
    /// pages behave identically.
    ///
    /// `window.readerSetHidden(list)` is also the host's entry point after it learns a
    /// phrase from the selection: it strips matching blocks from the article live, adds
    /// what it removed to the hit counts, and redraws the badge and list.
    ///
    /// `hitsJSON` is the extraction pass's `{normalizedPhrase: count}` (the reader page);
    /// the start page has no article and passes nothing.
    static func controlsScript(settings: ReaderSettings, hidden: HiddenPhrases = HiddenPhrases(),
                               hitsJSON: String = "{}", platform: Platform = .macOS) -> String {
        let sans = platform.sansStack
        let serif = platform.serifStack
        return """
        (function () {
          \(indent(HiddenPhrases.hideScript, by: 2))
          var s = \(settings.json);
          var HIDDEN = \(hidden.scriptLiteral);
          var HITS = \(hitsJSON);
          var MIN = \(ReaderSettings.fontSizeRange.lowerBound), MAX = \(ReaderSettings.fontSizeRange.upperBound);
          var FONTS = { serif: '\(serif)', sans: '\(sans)' };
          var WIDTHS = { narrow: '\(ReaderSettings.Width.narrow.css)', normal: '\(ReaderSettings.Width.normal.css)', wide: '\(ReaderSettings.Width.wide.css)' };
          var LEADINGS = { compact: '\(ReaderSettings.LineHeight.compact.css)', normal: '\(ReaderSettings.LineHeight.normal.css)', relaxed: '\(ReaderSettings.LineHeight.relaxed.css)' };
          var root = document.documentElement;
          var btn = document.getElementById('readerAa');
          var panel = document.getElementById('readerPanel');
          var recentsBtn = document.getElementById('readerRecentsBtn');
          var recents = document.getElementById('readerRecents');
          var hiddenBtn = document.getElementById('readerHiddenBtn');
          var hiddenPanel = document.getElementById('readerHidden');
          var hiddenList = document.getElementById('readerHiddenList');
          var badge = document.getElementById('readerHiddenCount');
          // The popovers, so opening one closes the others.
          var popovers = [{ btn: btn, panel: panel }, { btn: recentsBtn, panel: recents },
                          { btn: hiddenBtn, panel: hiddenPanel }];
          var REMOVE_ICON = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">' +
            '<path d="M18 6 6 18M6 6l12 12"/></svg>';

          function apply() {
            root.style.setProperty('--reader-size', s.fontSize + 'px');
            root.style.setProperty('--reader-font', FONTS[s.fontFamily]);
            root.style.setProperty('--reader-width', WIDTHS[s.width]);
            root.style.setProperty('--reader-leading', LEADINGS[s.lineHeight]);
            if (s.theme === 'auto') { root.removeAttribute('data-theme'); }
            else { root.setAttribute('data-theme', s.theme); }
            if (s.quoteStyle === 'italic') { root.setAttribute('data-quotes', 'italic'); }
            else { root.removeAttribute('data-quotes'); }
            panel.querySelectorAll('button[data-key]').forEach(function (b) {
              b.setAttribute('aria-pressed', String(s[b.dataset.key] === b.dataset.value));
            });
            panel.querySelector('button[data-step="-1"]').disabled = s.fontSize <= MIN;
            panel.querySelector('button[data-step="1"]').disabled = s.fontSize >= MAX;
            // Type metrics change how much there is to scroll, so anything tracking scroll
            // position has to re-measure. Only the reader page installs this (see
            // progressScript); the start page leaves it undefined.
            if (window.readerOnLayoutChange) { window.readerOnLayoutChange(); }
          }
          function save() {
            try { window.webkit.messageHandlers.readerSettings.postMessage(s); } catch (e) {}
          }
          // Opens one popover and closes the rest; `null` closes everything.
          function setOpen(which) {
            popovers.forEach(function (p) {
              var open = p.panel === which;
              p.panel.hidden = !open;
              p.btn.setAttribute('aria-expanded', String(open));
            });
          }
          panel.addEventListener('click', function (e) {
            var b = e.target.closest('button');
            if (!b || b.disabled) { return; }
            if (b.dataset.step) {
              s.fontSize = Math.min(MAX, Math.max(MIN, s.fontSize + Number(b.dataset.step)));
            } else if (b.dataset.key) {
              s[b.dataset.key] = b.dataset.value;
            } else { return; }
            apply(); save();
          });
          // Strips matching blocks from the article (the start page has none) and redraws
          // the list. Rows are built with DOM APIs from the phrase strings — phrases come
          // from other sites' pages and never take the markup path.
          window.readerSetHidden = function (list) {
            HIDDEN = list;
            var result = readerHideBlocks(document.querySelector('article'), HIDDEN);
            Object.keys(result.hits).forEach(function (k) { HITS[k] = (HITS[k] || 0) + result.hits[k]; });
            if (window.readerOnLayoutChange) { window.readerOnLayoutChange(); }
            // The badge counts blocks actually removed from this page — a phrase dropped
            // from the list later doesn't bring its blocks back until a reload.
            var total = 0;
            Object.keys(HITS).forEach(function (k) { total += HITS[k]; });
            badge.textContent = String(total);
            badge.hidden = total === 0;
            hiddenBtn.setAttribute('aria-label',
              total ? 'Hidden text, ' + total + ' removed from this article' : 'Hidden text');
            hiddenList.textContent = '';
            if (!HIDDEN.length) {
              var empty = document.createElement('p');
              empty.className = 'phrase-empty';
              empty.textContent = 'No hidden text';
              hiddenList.appendChild(empty);
              return;
            }
            function heading(label, extra) {
              var h = document.createElement('p');
              h.className = 'phrase-group' + (extra ? ' ' + extra : '');
              h.textContent = label;
              hiddenList.appendChild(h);
            }
            var hit = HIDDEN.filter(function (p) { return HITS[readerNormalize(p)]; });
            var rest = HIDDEN.filter(function (p) { return !HITS[readerNormalize(p)]; });
            if (hit.length) {
              heading('Removed from this article');
              hit.forEach(row);
              if (rest.length) { heading('Other phrases', 'rest'); }
            }
            rest.forEach(row);
            function row(phrase) {
              var row = document.createElement('div');
              row.className = 'phrase';
              var text = document.createElement('span');
              text.className = 'phrase-text';
              text.textContent = phrase;
              text.title = phrase;
              var count = HITS[readerNormalize(phrase)];
              if (count) {
                var chip = document.createElement('span');
                chip.className = 'phrase-count';
                chip.textContent = '×' + count;
              }
              var remove = document.createElement('button');
              remove.className = 'phrase-remove';
              remove.setAttribute('aria-label', 'Stop hiding “' + phrase + '”');
              remove.title = 'Stop hiding';
              remove.innerHTML = REMOVE_ICON;
              remove.addEventListener('click', function (e) {
                // Redrawing detaches the clicked button; without this the document-level
                // close handler would see a node outside .reader-controls and shut the panel.
                e.stopPropagation();
                window.readerSetHidden(HIDDEN.filter(function (p) { return p !== phrase; }));
                try { window.webkit.messageHandlers.readerUnhide.postMessage(phrase); }
                catch (err) {}
              });
              row.appendChild(text);
              if (count) { row.appendChild(chip); }
              row.appendChild(remove);
              hiddenList.appendChild(row);
            }
          };
          btn.addEventListener('click', function () { setOpen(panel.hidden ? panel : null); });
          recentsBtn.addEventListener('click', function () {
            setOpen(recents.hidden ? recents : null);
          });
          hiddenBtn.addEventListener('click', function () {
            setOpen(hiddenPanel.hidden ? hiddenPanel : null);
          });
          // A recents row hands its URL to the host, which re-validates it against the
          // app's domain scope before navigating — the same path an incoming link takes.
          recents.addEventListener('click', function (e) {
            if (e.target.closest('#readerClear')) {
              // Removing the button detaches the click target, so the document-level
              // close handler would see a node outside .reader-controls and hide the
              // panel — hiding the empty state we're about to show. Stop it here.
              e.stopPropagation();
              // Empty the panel in place — the host clears the stored list.
              recents.querySelectorAll('.recent, #readerClear').forEach(function (n) {
                n.remove();
              });
              recents.insertAdjacentHTML('beforeend',
                '<p class="recent-empty">No recent articles</p>');
              try { window.webkit.messageHandlers.readerClear.postMessage(''); }
              catch (err) {}
              return;
            }
            var row = e.target.closest('button[data-url]');
            if (!row) { return; }
            setOpen(null);
            try { window.webkit.messageHandlers.readerOpen.postMessage(row.dataset.url); }
            catch (err) {}
          });
          document.addEventListener('click', function (e) {
            if (!e.target.closest('.reader-controls')) { setOpen(null); }
          });
          document.addEventListener('keydown', function (e) {
            if (e.key !== 'Escape') { return; }
            // Return focus to the button that opened the popover being dismissed.
            var open = popovers.filter(function (p) { return !p.panel.hidden; })[0];
            if (open) { setOpen(null); open.btn.focus(); }
          });
          // Like / dislike the article being read. Present only on the reader page; the
          // host owns the toggle, and calls back with the rating now in force so the two
          // buttons can never both read as pressed.
          var moreBtn = document.getElementById('readerMoreBtn');
          var lessBtn = document.getElementById('readerLessBtn');
          if (moreBtn && lessBtn) {
            var rate = function (direction) {
              try { window.webkit.messageHandlers.readerRate.postMessage(direction); }
              catch (err) {}
            };
            moreBtn.addEventListener('click', function () { rate('more'); });
            lessBtn.addEventListener('click', function () { rate('less'); });
            // `silent` is set when the host is only restoring state (back/forward onto an
            // already-rendered page) — nothing was clicked, so nothing is announced.
            window.readerSetRating = function (rating, silent) {
              moreBtn.setAttribute('aria-pressed', rating === 'more' ? 'true' : 'false');
              lessBtn.setAttribute('aria-pressed', rating === 'less' ? 'true' : 'false');
              if (!silent && window.readerToast) {
                window.readerToast(rating === 'more' ? 'More articles like this from now on.'
                  : rating === 'less' ? 'Fewer articles like this from now on.'
                  : 'Preference cleared.');
              }
            };
          }

          apply();
          window.readerSetHidden(HIDDEN);
        })();
        """
    }
}
