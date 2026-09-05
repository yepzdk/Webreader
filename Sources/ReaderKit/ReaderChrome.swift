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

    /// One chrome offset from a window edge, grown by the device's safe-area inset there.
    ///
    /// Every `position: fixed` piece of chrome goes through this so a notch, a rounded
    /// corner or a home indicator cannot land on top of a control. On a desktop every
    /// inset is 0 and this is the fixed offset it has always been.
    ///
    /// The two-argument `env()` is deliberate. With no fallback the declaration is invalid
    /// in an engine that does not implement `env()`, and an invalid declaration is dropped
    /// — so the chrome would lose its offset altogether rather than fall back to it.
    private static func inset(_ px: Int, _ edge: String) -> String {
        "calc(\(px)px + env(safe-area-inset-\(edge), 0px))"
    }

    /// The touch-target floor, in px. 44 is Apple's HIG figure and clears the 24px WCAG
    /// 2.5.8 minimum the chrome already aimed at with padding; Material's 48dp is met by
    /// the padding the coarse blocks add around it.
    ///
    /// Applied only under `@media (pointer: coarse)`, never unconditionally: the desktop
    /// chrome is dense on purpose, and a mouse hits a 28px button without trying.
    ///
    /// Not private: every page states the same floor for its own controls, and a second
    /// copy of the number is how a floor drifts one control at a time.
    static let touchTarget = 44

    /// The `<meta name="viewport">` every generated page carries.
    ///
    /// `viewport-fit=cover` is not decoration: iOS resolves every `safe-area-inset-*` to
    /// 0px until a document opts in with it, so without this the insets the chrome, the
    /// toast and the popovers offset by are inert on the one platform they were added for.
    /// Opting in also lets the page paint under the notch and the home indicator, which is
    /// what those insets then hold the controls clear of.
    ///
    /// `initial-scale=1` with no `maximum-scale`: pinch-zoom stays available, because a
    /// reading app nobody can zoom is a reading app somebody cannot read.
    static let viewportMeta = "<meta name=\"viewport\" "
        + "content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"

    /// The single JS object name an Android host injects with
    /// `WebViewCompat.addWebMessageListener`. Named here so the host and the page cannot
    /// disagree about it, the way the message names themselves are agreed by being
    /// spelled once in `ReaderChrome` and once in each host's registration list.
    static let androidBridge = "readerHost"

    /// `window.readerPost(name, body)` — the one route a generated page has to its host,
    /// emitted in `<head>` so it is defined before any inline handler or later script can
    /// call it.
    ///
    /// It exists so the transport is one platform-selected line instead of a
    /// `window.webkit.messageHandlers` reference at every post site. `WKWebView` and
    /// WebKitGTK both expose that object under the same name, which is why the two current
    /// hosts never needed a seam; Android's WebView exposes no such thing. Its
    /// `addWebMessageListener` bridge injects one named object whose `postMessage` takes a
    /// single string, so there the name has to travel *with* the body as JSON and the host
    /// demultiplexes on the far side.
    ///
    /// Swallowing the error is carried over unchanged from the call sites this replaces: a
    /// page can outlive its host — restored from the back-forward cache, or simply opened
    /// in a browser while working on the CSS — and it must stay readable rather than
    /// throwing on every click.
    static func transportScript(platform: Platform) -> String {
        let send: String
        switch platform {
        case .macOS, .linux, .iOS:
            send = "window.webkit.messageHandlers[name].postMessage(body);"
        case .android:
            send = "window.\(androidBridge).postMessage("
                + "JSON.stringify({ name: name, body: body }));"
        }
        return """
        <script>
        window.readerPost = function (name, body) {
          try { \(send) } catch (err) {}
        };
        </script>
        """
    }

    /// The `data-theme`, `data-quotes` and `data-thumbs` attributes for `<html>`. Each is
    /// absent at its default (`auto` follows the system; bordered quotes are the
    /// stylesheet's baseline; thumbnails are on), so the stock page is attribute-free.
    ///
    /// `thumbnails` is the scope of *this page's* lists — `.startPage` or `.reader` — because
    /// each page renders only its own, and a page with no lists at all (settings, offline)
    /// passes nothing. Baked here so the first paint is right; `controlsScript` keeps the
    /// attribute in step with the same field afterwards.
    static func themeAttribute(_ settings: ReaderSettings,
                               thumbnails scope: ReaderSettings.ThumbnailScope? = nil) -> String {
        let thumbnails = scope.map { settings.thumbnails($0) } ?? .on
        return (settings.theme == .auto ? "" : " data-theme=\"\(settings.theme.rawValue)\"")
            + (settings.quoteStyle == .bordered ? "" : " data-quotes=\"\(settings.quoteStyle.rawValue)\"")
            + (thumbnails == .on ? "" : " data-thumbs=\"off\"")
    }

    /// The palette custom properties: light defaults, the dark media query, and the four
    /// explicit `[data-theme]` palettes. The attribute selectors deliberately come last so
    /// they outrank both the defaults and the media query.
    ///
    /// `platform` selects the reading font stack and defaults to macOS, so the AppKit host
    /// needs no argument; the Linux host passes `.linux`.
    ///
    /// `palette` is the host's desktop palette and is honoured **only under `.auto`** (#16).
    /// An explicit theme exists precisely to pin its own colours regardless of what the
    /// desktop is wearing, so it ignores the argument entirely. When a palette does apply
    /// it replaces the light defaults outright and the `prefers-color-scheme` block is
    /// dropped rather than emitted-and-overridden: the palette already answers the
    /// light/dark question, via `color-scheme`, and leaving a media query behind it would
    /// repaint a light desktop's reader dark the moment the system switch flipped.
    /// The `[data-theme]` selectors are always emitted — the Aa popover sets that attribute
    /// live, without a reload, so the explicit palettes must already be in the document.
    static func themeCSS(_ settings: ReaderSettings, platform: Platform = .macOS,
                         palette: ReaderPalette? = nil) -> String {
        let hosted = settings.theme == .auto ? palette : nil
        let rootPalette = hosted.map { properties($0, colorScheme: true) }
            ?? properties(.stock(for: .light, prefersDark: false), colorScheme: false)
        var blocks = ["""
        :root {
          \(indent(rootPalette, by: 2))
          --reader-size: \(settings.fontSize)px;
          --reader-leading: \(settings.lineHeight.css);
          --reader-width: \(settings.width.css);
          --reader-font: \(settings.fontFamily.css(on: platform));
        }
        """]
        if hosted == nil {
            blocks.append("""
            @media (prefers-color-scheme: dark) {
              :root {
                \(indent(properties(.stock(for: .dark, prefersDark: true), colorScheme: false), by: 4))
              }
            }
            """)
        }
        let pinned = [ReaderSettings.Theme.light, .sepia, .dark, .black].map { theme in
            """
            :root[data-theme="\(theme.rawValue)"] {
              \(indent(properties(.stock(for: theme, prefersDark: false), colorScheme: true), by: 2))
            }
            """
        }.joined(separator: "\n")
        blocks.append("""
        /* Explicit themes pin a palette; the attribute selector outranks both the
           light defaults and the dark media query above. */
        \(pinned)
        """)
        return blocks.joined(separator: "\n")
    }

    /// A palette's six custom properties, two declarations to a line, as every block in
    /// `themeCSS` has always written them. `colorScheme` adds the `color-scheme` line: the
    /// blocks that answer the light/dark question outright carry it, the light defaults and
    /// the dark media query (which the browser has already decided) do not.
    private static func properties(_ palette: ReaderPalette, colorScheme: Bool) -> String {
        var lines = [
            "--bg: \(palette.bg); --fg: \(palette.fg); --muted: \(palette.muted); --accent: \(palette.accent);",
            "--border: \(palette.border); --surface: \(palette.surface);",
        ]
        if colorScheme { lines.append("color-scheme: \(palette.isDark ? "dark" : "light");") }
        return lines.joined(separator: "\n")
    }

    /// The shared chrome button box: the same padding, colours, hairline and radius for the
    /// top-right cluster and the top-left nav slot. One declaration and two selector lists,
    /// so a button on one side of the window can't drift from a button on the other.
    ///
    /// The comfortable floor lives here for the same reason the box does: every chrome
    /// button on either side of the window grows together or none of them does. It applies
    /// on any touch host and in any compact viewport — see `comfortableChrome` for why the
    /// two are a union rather than one or the other. `inline-flex` is what makes
    /// `min-height` centre the label: the text buttons have no flex of their own, only the
    /// icon ones do.
    private static func buttonBox(_ selectors: String) -> String {
        """
        \(selectors) {
          padding: 4px 10px; font-family: inherit; font-size: 14px;
          color: var(--muted); background: var(--bg);
          border: 1px solid var(--border); border-radius: 6px; cursor: pointer;
        }
        @media \(comfortableChrome) {
          \(selectors) {
            display: inline-flex; align-items: center; justify-content: center;
            min-height: \(touchTarget)px; min-width: \(touchTarget)px; padding: 4px 14px;
          }
        }
        """
    }

    /// The top-left nav slot: one button on the same 14px baseline as the top-right cluster,
    /// so the two read as one row of chrome rather than two stray corners.
    ///
    /// Deliberately *not* a second `.reader-controls`: `controlsScript`'s outside-click
    /// dismissal keys off that class, and clicking the nav button must still close an open
    /// popover. The occupant differs per page (`navHome`, `navSettings`) and both ids are
    /// styled here, since a page renders one or the other and never both. Nothing here may
    /// reach for `--surface` — the offline page renders a nav button and defines no such
    /// custom property.
    static func navCSS(platform: Platform = .macOS) -> String {
        """
        .reader-nav {
          position: fixed; top: \(inset(14, "top")); left: \(inset(14, "left")); z-index: 10;
          display: flex; gap: 6px;
          font-family: \(platform.sansStack); font-size: 12px; line-height: 1.3;
        }
        \(buttonBox("#readerHomeBtn, #startSettings"))
        #readerHomeBtn:hover, #startSettings:hover { color: var(--fg); }
        /* The home icon matches the cluster's icon buttons; the SVG inherits currentColor.
           `justify-content` matters only once the coarse floor gives the box more width
           than the icon needs — without it the icon sits left of centre on touch. */
        #readerHomeBtn {
          display: flex; align-items: center; justify-content: center; padding: 5px 9px;
        }
        #readerHomeBtn svg { display: block; }
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
          position: fixed; top: \(inset(14, "top")); right: \(inset(14, "right")); z-index: 10;
          display: flex; gap: 6px;
          font-family: \(sans); font-size: 12px; line-height: 1.3;
        }
        /* Each button owns the popover anchored under it. */
        .reader-control { position: relative; }
        \(buttonBox("#readerAa, #readerRecentsBtn, #readerHiddenBtn"))
        #readerAa:hover, #readerAa[aria-expanded="true"],
        #readerRecentsBtn:hover, #readerRecentsBtn[aria-expanded="true"],
        #readerHiddenBtn:hover, #readerHiddenBtn[aria-expanded="true"] { color: var(--fg); }
        /* The icon buttons match the "Aa" button's box; the SVGs inherit currentColor.
           `justify-content` centres the icon once the coarse floor makes the box wider
           than the glyph needs; on a pointer the box is content-sized and it does nothing. */
        #readerRecentsBtn, #readerHiddenBtn, #readerMoreBtn, #readerLessBtn {
          display: flex; align-items: center; justify-content: center; padding: 5px 9px;
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
          /* Every panel hangs leftward from a right-anchored button, so each needs the same
             guard against running off the opposite edge — not just the two list panels that
             historically had it. */
          max-width: calc(100vw - 28px);
          padding: 12px; background: var(--bg);
          border: 1px solid var(--border); border-radius: 8px;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12);
          display: flex; flex-direction: column; gap: 10px;
        }
        #readerPanel[hidden], #readerRecents[hidden], #readerHidden[hidden] { display: none; }
        /* Recents: two short groups of rows. Padding is on the rows, so the panel itself
           sheds its gap. Right-anchored like the Aa panel: the controls sit at the window's
           right edge, so the panel has to hang leftward to stay on screen. `max-width` keeps
           it from running off the LEFT edge on a narrow window.
           The height cap was 60vh when this listed the whole 30-entry history. Ten rows with
           thumbnails and two-line titles measure ~660px, which 60vh only clears on an
           1100px-tall window; 76vh fits them from ~870px up, and still cannot overflow the
           viewport — the panel starts ~52px down, and 24vh is more than that above 220px. */
        #readerRecents, #readerHidden {
          width: 280px; max-width: calc(100vw - 28px);
          padding: 6px; gap: 0; max-height: 76vh; overflow-y: auto;
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
        /* Two lines in the popover as well as inline (#33): a 64px thumbnail and its gap
           leave roughly 194px of title in a 280px panel, and one line cuts most Danish
           headlines before they say what the article is about. Still clamped — a row is a
           glance, not the article. */
        #readerRecents .recent-title {
          white-space: normal;
          display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2;
        }
        /* Thumbnails (#25), for recents and suggestions alike, on the start page and in the
           reader's popover (#33). A grid rather than a flex line, and only in a list carrying
           `has-thumbs` — set by the server for rendered rows and by the host's callback for
           delivered ones, in both cases only when something in that list actually has an
           image. The text column is pinned, so a row whose article named no image still lines
           its title up with the rest instead of starting 74px to their left, and a list with
           no images at all is laid out exactly as it always was. */
        .has-thumbs .recent {
          display: grid; grid-template-columns: 64px 1fr; gap: 0 10px; align-items: start;
        }
        .has-thumbs .recent-thumb { grid-row: 1 / span 2; }
        /* Pinned, or auto-placement would drop an imageless row's title into the 64px
           column and squeeze it. */
        .has-thumbs .recent-title,
        .has-thumbs .recent-host { grid-column: 2; }
        /* 64x40 rather than a square: a lead image is usually landscape, and this is about
           the height two clamped title lines already take, so rows barely grow. */
        .recent-thumb {
          width: 64px; height: 40px; object-fit: cover;
          border-radius: 4px; background: var(--surface);
        }
        /* The empty slot. Only ever shown inside a list that has a column at all, so a
           list where nothing has an image is laid out exactly as it was before #25. */
        .recent-thumb-empty { display: none; }
        .has-thumbs .recent-thumb-empty {
          display: flex; align-items: center; justify-content: center;
          color: var(--muted); opacity: 0.45;
        }
        .recent-thumb-empty svg { display: block; }
        /* Article images off: no image, no reserved column, and nothing fetched — the
           appearance script is the only thing that ever sets a src. Load-bearing on both
           pages now, so it travels with the rest of the block rather than staying behind. */
        :root[data-thumbs="off"] .recent-thumb { display: none; }
        :root[data-thumbs="off"] .has-thumbs .recent { display: block; }
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
        /* Group labels inside a list panel: the hidden-text panel puts the phrases that hit
           this article first and the rest under a rule, and the recents panel separates its
           suggested group the same way. */
        .panel-group {
          margin: 6px 6px 2px; padding: 0 2px; font-size: 10px; font-weight: 600;
          letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted);
        }
        .panel-group.rest { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--border); }
        /* Clearing history lives next to the history itself — Restore Defaults is for
           presentation settings and deliberately leaves user data alone. */
        #readerClear {
          margin: 4px 6px 2px; padding: 6px 8px; border: 0; border-top: 1px solid var(--border);
          border-radius: 0; background: transparent; cursor: pointer; text-align: left;
          font-family: inherit; font-size: 11px; color: var(--muted);
        }
        #readerClear:hover { color: var(--fg); }
        /* Clear history already draws a rule, so the suggested group below it doesn't draw a
           second one 8px away. With no history there is no clear button and the heading
           keeps its own. */
        #readerClear + #readerSuggested > .panel-group.rest {
          margin-top: 8px; padding-top: 0; border-top: 0;
        }
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
        /* Two blocks at the end, so source order settles every override without a
           specificity fight. They answer different questions, which is why they are two.

           First: where a panel goes. That follows the chrome, so it is keyed on viewport
           size. Every panel is `right: 0` inside its own `.reader-control`, and the recents
           button is the third of five — so its right edge is ~273px in from the left on a
           390px phone, and any panel wider than that starts off-screen. Measured at -47px
           before this existed: the `max-width` guard never fired, because the panel was
           narrower than the viewport and still outside it. Widening a right-anchored panel
           cannot fix that; only re-anchoring can. `position: fixed` escapes the
           `.reader-control` containing block without changing DOM ancestry, so
           `controlsScript`'s outside-click dismissal keys off the same `.reader-controls`
           it always did. */
        @media \(compactViewport) {
          #readerPanel, #readerRecents, #readerHidden {
            position: fixed;
            /* Anchored to the bottom now, not the top: the chrome that opens these sits in
               the bottom-right corner, and a panel that appeared at the far end of the
               screen from the button you just pressed would be a different gesture
               entirely. It grows upward from just above the toggle — which is all that is
               left on screen, because opening a panel collapses the stack. */
            top: auto;
            bottom: calc(\(chromeEdge + touchTarget + chromeGap)px
                         + env(safe-area-inset-bottom, 0px));
            left: max(\(chromeEdge)px, env(safe-area-inset-left, 0px));
            right: max(\(chromeEdge)px, env(safe-area-inset-right, 0px));
            width: auto;
            /* Full width on a portrait phone, but a landscape one is 844px wide and a
               816px band of 13px rows is not a list anyone wants to read. Capped, and
               pushed back to the right so it still reads as hanging from the cluster that
               opened it. */
            max-width: 30rem; margin-left: auto;
            max-height: calc(100vh - \(chromeEdge * 2 + touchTarget + chromeGap)px
                             - env(safe-area-inset-top, 0px)
                             - env(safe-area-inset-bottom, 0px));
            overflow-y: auto;
          }
        }
        /* Second: how big the rating pair is. It is chrome — it stands in the column beside
           the other buttons — but it sits outside `buttonBox`, carrying its own box so the
           pressed accent state can override it. So it needs the same union `buttonBox` uses,
           or a narrow mouse window gets five 44px buttons and two 27px ones. */
        @media \(comfortableChrome) {
          #readerMoreBtn, #readerLessBtn {
            min-height: \(touchTarget)px; min-width: \(touchTarget)px; padding: 5px 12px;
          }
        }
        /* Third: how big the controls *inside* a panel are. That asks what is pointing at
           them, so it stays on the pointer alone. A mouse hits a 32px row without trying,
           and growing every row on a narrow desktop window would make the panel feel
           clumsy — the chrome grows there because a floating column over content wants air
           around it, which a list you read does not. */
        @media (pointer: coarse) {
          .recent { min-height: \(touchTarget)px; padding: 10px 10px; font-size: 13px; }
          .recent-empty, .phrase-empty { padding: 10px; }
          .seg button { min-height: \(touchTarget)px; padding: 0 4px; }
          .swatch { width: 34px; height: 34px; }
          .themes { padding: 2px 0; }
          /* The X on a hidden-phrase row: a 20px icon box inside a list built for reading. */
          .phrase-remove { min-height: \(touchTarget)px; min-width: \(touchTarget)px; }
        }
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
          position: fixed; left: 50%; bottom: \(inset(20, "bottom"));
          transform: translateX(-50%) translateY(6px);
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
          position: fixed; top: env(safe-area-inset-top, 0px); left: 0; width: 100%;
          height: \(LoadProgress.lineThickness)px; z-index: 9;
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

    /// The gradient behind the fixed chrome, and the element it paints on.
    ///
    /// The article scrolls *under* the chrome, and a button's own `--bg` only covers the
    /// button — the gaps between them, and the space between the two corners, let text
    /// through. The result is a line of article running between the icons, with neither the
    /// text nor the icons readable.
    ///
    /// A gradient rather than a bar: it fades to nothing instead of drawing a toolbar edge
    /// across a page whose whole point is not having one. And it costs no script and no
    /// state, because it is invisible until something is behind it — `--bg` over `--bg` is
    /// no change, so at the top of the document there is nothing to see, and the fade only
    /// reads once text has scrolled up into it.
    ///
    /// `z-index: 7` puts it under everything that has to stay legible over it — the hide
    /// affordance (8), the progress line (9) and the chrome itself (10) — and over the
    /// article, which is in normal flow. `pointer-events: none` so a band across the top of
    /// the page doesn't swallow taps meant for the text under it.
    ///
    /// The height is the chrome's own geometry plus room to fade, rather than a number that
    /// happened to clear it: the cluster ends `chromeEdge + touchTarget` below the safe
    /// area — 58px, since `comfortableChrome` includes `(pointer: coarse)` and a roomy
    /// touch viewport therefore gets 44px buttons — and the solid stop sits exactly there.
    /// Sized against the 41px pointer cluster instead, it ended 11px short and left article
    /// text running between the icons on a tablet.
    ///
    /// It exists only for the roomy layout. On a compact viewport the chrome has moved to
    /// the bottom-right corner (see `chromeCSS`), so a fade along the top edge would be a
    /// gradient over nothing — the only thing left up there is the progress hairline, and a
    /// 2.5px line needs no backing to stay legible.
    static func backdropCSS() -> String {
        """
        #readerBackdrop {
          position: fixed; top: 0; left: 0; right: 0; z-index: 7;
          height: calc(\(chromeEdge + touchTarget + backdropFade)px
                       + env(safe-area-inset-top, 0px));
          pointer-events: none;
          background: linear-gradient(to bottom, var(--bg) 0%,
            var(--bg) calc(\(chromeEdge + touchTarget)px + env(safe-area-inset-top, 0px)),
            transparent 100%);
        }
        @media \(compactViewport) {
          #readerBackdrop { display: none; }
        }
        """
    }

    /// `aria-hidden` because it is a legibility device with no content of its own.
    static func backdrop() -> String {
        "<div id=\"readerBackdrop\" aria-hidden=\"true\"></div>"
    }

    /// The gap between stacked chrome buttons, and the chrome's inset from the window edge.
    /// Shared with `inset(_:_:)` so the bottom-right column and the popovers that open above
    /// it agree on where the stack ends without either measuring the other.
    private static let chromeGap = 10
    private static let chromeEdge = 14

    /// How far the backdrop keeps fading after the chrome it backs has ended. Enough that
    /// the band reads as a fade rather than a toolbar edge, and no more.
    private static let backdropFade = 24

    /// The buttons that live in the collapsing stack, by id — everything the column holds
    /// except the toggle, which is the one control that never hides.
    ///
    /// Spelled out rather than reached through the tree. Hiding used to run through
    /// `.reader-chrome[data-collapsible]:not([data-open]) .reader-nav > button`, which is
    /// four links of structure to say "these seven buttons" — and every link is a chance
    /// for the engine to mis-invalidate, which is exactly what it did. A list of ids says
    /// the same thing in a form that cannot drift from the markup without failing loudly,
    /// and that you can look up directly in an inspector.
    static let stackButtonIDs = ["readerHomeBtn", "startSettings", "readerAa",
                                 "readerRecentsBtn", "readerHiddenBtn",
                                 "readerMoreBtn", "readerLessBtn"]

    /// The same list plus the toggle: everything that takes the column's square sizing.
    static let chromeButtonIDs = stackButtonIDs + ["readerChromeToggle"]

    /// The attribute the script puts on a chrome button that is currently revealed.
    ///
    /// On the button, not on an ancestor. Two earlier versions of this hung the state on
    /// `.reader-chrome` and then on `:root`, and both left buttons painted after a collapse
    /// until an unrelated resize forced the engine to re-resolve them. An attribute written
    /// to the element itself cannot miss it, and it is the state you see when you inspect
    /// the button you are asking about.
    static let chromeOpenAttr = "data-chrome-open"

    /// `ids` as a CSS selector list, each optionally carrying `suffix`.
    ///
    /// One id per line so a stylesheet stays readable at eight of them, and so a diff shows
    /// which button changed rather than one reflowed line.
    private static func selector(_ ids: [String], suffix: String = "") -> String {
        ids.map { "#\($0)\(suffix)" }
            .joined(separator: ",\n          ")
    }

    /// The viewport at which the chrome collapses into one bottom-right column.
    ///
    /// Size, not input device. Hiding the controls answers "is there room for them beside
    /// the article?", and on a small viewport there is not — six buttons parked over prose
    /// compete with the prose whether a finger or a cursor put them there. A narrow desktop
    /// window has exactly the problem a phone does.
    ///
    /// Width *or* height: a phone in landscape is 844px wide and 390px tall, so a width
    /// test alone would leave it with the top cluster eating a fifth of the screen. 48rem
    /// is where the window stops being much wider than the reading column itself (the
    /// widest `--reader-width` is 48rem); 30rem is where there is no vertical room to spare.
    ///
    /// Written as a comma list rather than a Level 4 `or`, which WebKitGTK cannot be relied
    /// on for — which is also why nothing combines this with `and`.
    static let compactViewport = "(max-width: 48rem), (max-height: 30rem)"

    /// Where the chrome's buttons take the comfortable 44px sizing: any touch host, and any
    /// compact viewport whatever is pointing at it.
    ///
    /// The union is deliberate. A tablet is roomy but touched, so it needs the target
    /// without collapsing; a narrow desktop window is moused but cramped, and a floating
    /// column over content wants air around it there too. Only the roomy pointer layout —
    /// the two top corners — keeps its original density.
    static let comfortableChrome = "(pointer: coarse), " + compactViewport

    /// Wraps the nav slot and the control cluster in one element, plus — where a page has
    /// more than one control — the button that reveals them.
    ///
    /// In the roomy layout the wrapper holds nothing: its two children are `position:
    /// fixed` to the opposite top corners they have always had, so the layer measures 0x0.
    /// The whole point is the compact layout, where they come back into flow and become one
    /// bottom-right column (see `chromeCSS`) — which a wrapper is the only way to express,
    /// since CSS cannot reparent two elements into a shared flex line.
    ///
    /// DOM order is stack-then-toggle. `.reader-chrome` runs as a plain column so the
    /// toggle lands at the foot, and the stack inside it reverses so the nav slot — first
    /// in the markup — ends up nearest the thumb. Bottom-up the column reads: toggle, Home,
    /// Aa, hidden text, recents, less, more. Home is nearest because going back is the one
    /// action you take without reading anything first, and the cluster keeps its document
    /// order so its right-to-left arrangement on a pointer becomes bottom-to-top here.
    ///
    /// `collapsible` is false only for a page whose chrome is a single button (settings,
    /// offline): a control that reveals one control is a tap for nothing, and with one
    /// button there is no popover for it to stand behind. Those pages still get the
    /// bottom-right position, which is the half of this that is about reach.
    ///
    /// Everything with two or more controls collapses, and that is what keeps the geometry
    /// uniform: a popover has to clear exactly one 44px button, because the toggle is all
    /// that is ever left beside it. The start page's two buttons would otherwise have stood
    /// behind its own appearance panel.
    static func chrome(nav: String, controls: String = "",
                       collapsible: Bool = false) -> String {
        let toggle = !collapsible ? "" : """
        <button id="readerChromeToggle" type="button" aria-label="Show reader controls"
                  title="Reader controls" aria-expanded="false" aria-controls="readerChromeStack">
            <!-- ellipsis-vertical, Lucide-style line icon; swapped for the X when open -->
            <svg class="chrome-toggle-open" width="15" height="15" viewBox="0 0 24 24"
                 fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
                 aria-hidden="true">
              <circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/>
              <circle cx="12" cy="19" r="1"/>
            </svg>
            <svg class="chrome-toggle-close" width="15" height="15" viewBox="0 0 24 24"
                 fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
                 aria-hidden="true">
              <path d="M18 6 6 18M6 6l12 12"/>
            </svg>
          </button>
        """
        return """
        <div class="reader-chrome">
          <div class="reader-chrome-stack" id="readerChromeStack">
            \(indent(nav, by: 4))
            \(indent(controls, by: 4))
          </div>
          \(toggle)
        </div>
        """
    }

    /// The chrome's compact layout: one collapsing column in the bottom-right.
    ///
    /// Two complaints, from reading on an actual phone. The cluster sat along the top edge,
    /// which is the hardest place there to reach one-handed; and six always-visible buttons
    /// over prose compete with the prose. So on a small viewport the chrome moves into the
    /// bottom-right corner and, where there is more than one control, hides behind a single
    /// button until asked for.
    ///
    /// Keyed on `compactViewport` — size, not input device. The distraction is a question of
    /// whether there is room for the controls beside the article, which a narrow desktop
    /// window answers the same way a phone does. Only the button *sizing* asks what is
    /// pointing at them (`comfortableChrome`).
    ///
    /// **Two rules about how this is written, both paid for.**
    ///
    /// *No `display` switch on any ancestor of a chrome button.* The wrapper used to be
    /// `display: contents` and become `display: flex` at the media boundary. That is a
    /// display change on an ancestor of every button in the column, and the layout stopped
    /// resolving reliably across it: buttons stayed visible after a collapse and corrected
    /// themselves on the next resize. The wrapper is now a fixed layer in both layouts —
    /// in the roomy one its two clusters take themselves out of flow to their own top
    /// corners, so it holds nothing and measures 0x0.
    ///
    /// *Collapsing removes the buttons' boxes, and each button carries its own open state.*
    ///
    /// Three attempts moved the state closer to the button — ancestor class, then `:root`
    /// attribute, then an attribute on the button itself — and none of them fixed the
    /// report, because the state was never the problem. The property was: `visibility:
    /// hidden` stops a button being painted but leaves its box, so the collapsed column
    /// still measured 44x314 and stood above the toggle in every state. `display: none`
    /// removes the box, which is what "collapsed" was always supposed to mean, and takes
    /// the tab order with it exactly as `visibility` did.
    ///
    /// The per-button attribute is kept: it is the state you can read on the node you are
    /// asking about, rather than one inherited from an ancestor three levels up.
    ///
    /// The cost is the 140ms fade, which `display` cannot animate. Accepted rather than
    /// worked around: it was 140ms on a control that appears under your thumb, and the
    /// alternatives all reintroduce an ancestor whose `display` switches.
    ///
    /// Collapsed is the *default* rather than a state the script applies, so the first
    /// paint is right without waiting for script.
    ///
    /// `collapsible` is false for a page whose chrome is a single button; it then emits no
    /// hiding at all, which is what stops the settings and offline pages from tucking away
    /// the only control they have.
    static func chromeCSS(platform: Platform = .macOS, collapsible: Bool = false) -> String {
        let collapsing = !collapsible ? "" : """
          /* Collapsed removes the box, not just the paint. `visibility: hidden` was the
             wrong property: it stops a button being drawn but leaves its 44px box, and six
             of those plus their gaps left a 314px invisible column standing above the
             toggle in every state. Measured, not assumed. */
          \(selector(stackButtonIDs, suffix: ":not([\(chromeOpenAttr)])")) {
            display: none;
          }
          /* Written as `:not(...)` rather than a hidden rule plus a reveal rule, because
             these buttons do not share one `display`: some compute `flex` and some
             `inline-flex`. Restating a single value on reveal would quietly change half of
             them. This way a revealed button simply keeps the display it already had. */
          /* The stack leaves the flow, so nothing it holds can push the toggle off the
             corner; it hangs directly above it and is empty when collapsed. */
          .reader-chrome-stack {
            position: absolute; right: 0; bottom: calc(100% + \(chromeGap)px);
          }
        """
        return """
        /* A fixed layer in both layouts — never `display: contents`, see the note above.
           Roomy: the clusters are `position: fixed` to their own corners, so this holds
           nothing. Compact: they come back into flow and this is the column. */
        .reader-chrome {
          position: fixed; z-index: 10;
          bottom: \(inset(chromeEdge, "bottom")); right: \(inset(chromeEdge, "right"));
          display: flex; flex-direction: column; align-items: flex-end;
          gap: \(chromeGap)px;
          font-family: \(platform.sansStack); font-size: 12px; line-height: 1.3;
        }
        /* `column` on the wrapper puts the toggle at the foot; `column-reverse` here sends
           the nav slot — first in the markup — to the bottom of the stack, directly above
           it. Bottom-up: toggle, Home, Aa, hidden text, recents, less, more. */
        .reader-chrome-stack {
          display: flex; flex-direction: column-reverse; align-items: flex-end;
          gap: \(chromeGap)px;
        }
        @media \(compactViewport) {
          /* The two clusters stop being fixed and become rows of the column. */
          .reader-nav, .reader-controls {
            position: static; top: auto; right: auto; left: auto;
            flex-direction: column; align-items: flex-end; gap: \(chromeGap)px;
          }
        \(collapsing)
          /* The toggle swaps its glyph rather than its box, so nothing shifts on open. */
          #readerChromeToggle .chrome-toggle-close,
          #readerChromeToggle[aria-expanded="true"] .chrome-toggle-open { display: none; }
          #readerChromeToggle[aria-expanded="true"] .chrome-toggle-close { display: block; }
        }
        /* The toggle's box comes from the same shared declaration as every other chrome
           button, so it cannot drift from the controls it reveals. */
        \(buttonBox("#readerChromeToggle"))
        /* It exists only for the compact layout; `display` is settled last, after the box. */
        #readerChromeToggle { display: none; }
        /* The roomy slot says the word and hides the icon; the column reverses it below. */
        #startSettings .nav-icon { display: none; }
        @media \(compactViewport) {
          #readerChromeToggle {
            display: inline-flex; align-items: center; justify-content: center;
          }
          #readerChromeToggle svg { display: block; }
          /* Every button in the column is the same square, so the stack reads as one edge:
             "Aa" is text and measured 47px against an icon button's 44px. Only here — on a
             line, a wider "Aa" beside narrower icons is exactly right. */
          \(selector(chromeButtonIDs)) {
            width: \(touchTarget)px; padding: 0;
          }
          #startSettings .nav-label { display: none; }
          #startSettings .nav-icon { display: block; }
        }
        """
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
    static func recentsRows(_ history: ReaderHistory, thumbnails: Bool = false) -> String {
        history.entries.map { entry in
            let host = URL(string: entry.url)?.host ?? ""
            let hostLine = host.isEmpty ? ""
                : "<span class=\"recent-host\">\(HTML.escape(host))</span>"
            return "<button class=\"recent\" data-url=\"\(HTML.escape(entry.url))\">"
                + (thumbnails ? thumbnail(entry) : "")
                + "<span class=\"recent-title\">\(HTML.escape(entry.title))</span>"
                + "\(hostLine)</button>"
        }.joined(separator: "\n")
    }

    /// What fills a thumbnail slot when the article named no image: the same box, in the
    /// row surface, with a quiet picture glyph.
    ///
    /// A slot rather than a gap. Coverage is uneven by nature — an article need not name an
    /// image and plenty of feeds name none — so a list will normally mix the two, and leaving
    /// the column blank on those rows reads as a failed load rather than as a design.
    ///
    /// Only ever rendered into a list that carries `has-thumbs`; the CSS keeps it out of a
    /// list where nothing has an image, so such a list looks exactly as it always did.
    static let thumbnailPlaceholder =
        "<span class=\"recent-thumb recent-thumb-empty\" aria-hidden=\"true\">"
        + "<svg width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\""
        + " stroke=\"currentColor\" stroke-width=\"1.75\" stroke-linecap=\"round\""
        + " stroke-linejoin=\"round\">"
        + "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/>"
        + "<circle cx=\"9\" cy=\"9\" r=\"1.5\"/>"
        + "<path d=\"m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21\"/>"
        + "</svg></span>"

    /// A row's lead-image thumbnail, or the placeholder when the article named none.
    ///
    /// The URL goes in `data-src`, not `src`: `readerRevealThumbs` is the only thing that ever
    /// promotes one to a fetch, so with article images off the page requests nothing — which
    /// is what the start page did before this existed. `no-referrer` keeps the reading list
    /// from travelling back to the publisher, and an image that fails falls back to the
    /// placeholder rather than leaving a broken glyph.
    private static func thumbnail(_ entry: ReaderHistory.Entry) -> String {
        guard let image = entry.image, !image.isEmpty else { return thumbnailPlaceholder }
        return "<img class=\"recent-thumb\" alt=\"\" loading=\"lazy\""
            + " referrerpolicy=\"no-referrer\""
            + " onerror=\"this.insertAdjacentHTML('afterend', window.readerThumbPlaceholder);"
            + " this.remove()\""
            + " data-src=\"\(HTML.escape(image))\">"
    }

    /// How many rows each of the popover's two groups carries. Short and fixed: the panel
    /// used to be the entire 30-entry history in a 60vh scroller, where nobody ever reached
    /// row 24 (#33).
    static let popoverRecents = 5
    static let popoverSuggestions = 5

    /// The recents popover's contents: the recents group — heading, rows, and the clear
    /// action — then the suggested group the host fills in later.
    ///
    /// Rows carry thumbnails, as the start page's lists do, and the column is reserved only
    /// when something in this list has an image — the same rule the inline list follows.
    /// `history` arrives already trimmed by the caller (`ReaderHistory.recents(limit:
    /// excluding:)`), so this renders exactly what it is given.
    ///
    /// `canClear` is asked separately because the trimmed list can be empty while the stored
    /// history is not: read one article and the only entry is the one on screen, which the
    /// popover deliberately excludes. The rows say "nothing else to go back to"; the button
    /// has to follow the store, or there would be history with no way to clear it.
    ///
    /// The two lists are separate containers because `has-thumbs` is a per-list decision and
    /// the clear action empties one of them in place.
    static func recentsBody(_ history: ReaderHistory, canClear: Bool) -> String {
        // Matches the script-side rule (`!!item.image`): an entry carrying an empty string
        // renders a placeholder, so it must not be what reserves the column.
        let hasThumbs = history.entries.contains { !($0.image ?? "").isEmpty }
        let rows = history.entries.isEmpty
            ? emptyRecentsMarkup
            : recentsRows(history, thumbnails: hasThumbs)
        let clear = canClear ? "\n<button id=\"readerClear\">Clear history</button>" : ""
        return """
        <h2 class="panel-title" id="readerRecentsTitle">Recent articles</h2>
        <div id="readerRecentsList"\(hasThumbs ? " class=\"has-thumbs\"" : "")>
          \(indent(rows, by: 2))
        </div>\(clear)
        <section id="readerSuggested" hidden aria-labelledby="readerSuggestedTitle">
          <h3 class="panel-group rest" id="readerSuggestedTitle">Suggested</h3>
          <div id="readerSuggestedList"></div>
        </section>
        """
    }

    /// The recents empty state. One definition: the server renders it, and the clear action
    /// swaps it in client-side (through `window.readerEmptyRecents`), so the two cannot come
    /// to word it differently.
    static let emptyRecentsMarkup = "<p class=\"recent-empty\">No recent articles</p>"

    /// The nav slot's occupant on the reader and offline pages: back to the start page.
    ///
    /// The click posts inline rather than through `controlsScript`, because the offline page
    /// carries no chrome script at all — one mechanism for one button beats a listener here
    /// and an inline handler there. `readerPost` is defined in `<head>`, so it is already
    /// there by the time a click can happen.
    static func navHome() -> String {
        """
        <div class="reader-nav">
          <button id="readerHomeBtn" type="button" aria-label="Home" title="Start page"
                  onclick="readerPost('readerHome', '')">
            <!-- house, Lucide-style line icon -->
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                 stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/>
              <path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
            </svg>
          </button>
        </div>
        """
    }

    /// The start page's nav occupant. The start page *is* home, so the slot carries the one
    /// piece of navigation it does have — and Settings sits where Home sits on every other
    /// page instead of hiding in the opposite corner.
    ///
    /// Carries both an icon and a word, and `chromeCSS` swaps them: the roomy top-left slot
    /// has room to say "Settings", while the compact column is squares and a text button
    /// would be the one wide row in it. Same trick the toggle uses for its own two glyphs,
    /// for the same reason — CSS can hide a child, not rewrite one.
    ///
    /// `aria-label` is on the button either way, so the word disappearing costs a screen
    /// reader nothing.
    static func navSettings() -> String {
        """
        <div class="reader-nav">
          <button id="startSettings" type="button" aria-label="Settings"
                  onclick="readerPost('readerOpenSettings', '')">
            <!-- settings-2 (sliders), Lucide-style line icon; shown only in the column -->
            <svg class="nav-icon" width="15" height="15" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="2" stroke-linecap="round"
                 aria-hidden="true">
              <path d="M20 7h-9"/><path d="M14 17H5"/>
              <circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>
            </svg>
            <span class="nav-label">Settings</span>
          </button>
        </div>
        """
    }

    /// The chrome markup: the "Aa" button with the appearance popover, plus — where the page
    /// asks for them — the recents button with its popover and the hidden-text button with
    /// its (script-filled) list. All carry hover tooltips and name their own panel, since the
    /// buttons themselves are unlabelled.
    ///
    /// Everything but the appearance popover is opt-in, the way `showsRating:` already is.
    /// `rating` adds the like/dislike pair — the reader page passes the current article's
    /// rating (nil = unrated); the start page omits it, since there is no article to rate.
    /// The start page also omits both lists (#32): its recents live inline in the page, where
    /// they get thumbnails and two-line titles, and it has no article for the hidden-text
    /// panel to group phrases against, so every phrase would fall under "the rest".
    /// `recents` is the popover's list — already trimmed, and `nil` on a page that renders no
    /// popover, so the data cannot go missing while the button is asked for or be handed to a
    /// page that discards it. `canClear` follows the stored history rather than that list; see
    /// `recentsBody`.
    static func controls(recents: ReaderHistory? = nil,
                         canClear: Bool = false,
                         showsRating: Bool = false,
                         rating: TopicPreferences.Rating? = nil,
                         showsHidden: Bool = false) -> String {
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
        let recentsControl = recents == nil ? "" : """
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
              \(indent(recentsBody(recents ?? ReaderHistory(), canClear: canClear), by: 6))
            </div>
          </div>
        """
        let hiddenControl = !showsHidden ? "" : """
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
        """
        return """
        <div class="reader-controls">
          \(ratingControls)
          \(recentsControl)
          \(hiddenControl)
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
    /// `window.readerSetSettings(next)` is the host's entry point for a document it did not
    /// just render — a back/forward restore reuses the original bytes, so its `s` is as old as
    /// the document and would otherwise be posted back over newer values by the next `save()`.
    ///
    /// `thumbnails` names the switch this page's lists obey; the script reads `s[THUMBS]`, so
    /// a pushed settings object drives `data-thumbs` exactly as the server-rendered attribute
    /// did. `hitsJSON` is the extraction pass's `{normalizedPhrase: count}` (the reader page);
    /// the start page has no article and passes nothing.
    static func controlsScript(settings: ReaderSettings,
                               thumbnails: ReaderSettings.ThumbnailScope,
                               hidden: HiddenPhrases = HiddenPhrases(),
                               hitsJSON: String = "{}", platform: Platform = .macOS) -> String {
        let sans = platform.sansStack
        let serif = platform.serifStack
        return """
        (function () {
          \(indent(HiddenPhrases.hideScript, by: 2))
          var s = \(settings.json);
          var THUMBS = '\(thumbnails.rawValue)';
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
          // The popovers, so opening one closes the others. Built from what this page
          // actually rendered rather than from what the chrome can emit: the start page
          // carries the appearance popover alone (#32), and the shared script must no more
          // assume the other two than it assumes the progress bar.
          var popovers = [{ btn: btn, panel: panel }, { btn: recentsBtn, panel: recents },
                          { btn: hiddenBtn, panel: hiddenPanel }]
            .filter(function (p) { return p.btn && p.panel; });
          var REMOVE_ICON = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">' +
            '<path d="M18 6 6 18M6 6l12 12"/></svg>';
          // The placeholder markup lives in Swift so every list that fills a thumbnail slot
          // from script — the start page's suggestions, the popover's — renders the same box
          // the server-rendered rows do. Ours, never feed text.
          window.readerThumbPlaceholder = \(HTML.jsString(thumbnailPlaceholder));
          // Likewise the recents empty state, which the clear action swaps in: one wording,
          // whether the server rendered it or the panel did.
          window.readerEmptyRecents = \(HTML.jsString(emptyRecentsMarkup));

          // The only thing in the app that ever sets a thumbnail's src. Rows are rendered
          // carrying `data-src` and nothing else, so while article images are off the page
          // asks the publishers for nothing at all — which is what the start page did before
          // thumbnails existed. Called by `apply`, and again whenever the host delivers rows,
          // which arrive long after this has first run.
          window.readerRevealThumbs = function () {
            if (root.getAttribute('data-thumbs') === 'off') { return; }
            document.querySelectorAll('.recent-thumb').forEach(function (img) {
              // A row inside a closed panel asks for nothing until the panel is opened.
              // Whether an engine honours loading="lazy" inside display:none is not worth
              // betting ten thumbnail fetches per article render on, and the popover is
              // closed on every render.
              if (img.closest('[hidden]')) { return; }
              if (!img.getAttribute('src') && img.dataset.src) { img.src = img.dataset.src; }
            });
          };

          // How the host hands a document it did not just render the settings as they now
          // stand. A back/forward restore reuses the original bytes, so `s` is as old as the
          // document: without this the next `save()` would post those stale values back over
          // whatever the settings page changed in between, and `readerSettings` replaces the
          // stored object. Assign, apply, and deliberately do not save — this is the store
          // telling the page, not the other way round.
          window.readerSetSettings = function (next) {
            if (!next) { return; }
            Object.keys(next).forEach(function (key) { s[key] = next[key]; });
            apply();
          };

          function apply() {
            root.style.setProperty('--reader-size', s.fontSize + 'px');
            root.style.setProperty('--reader-font', FONTS[s.fontFamily]);
            root.style.setProperty('--reader-width', WIDTHS[s.width]);
            root.style.setProperty('--reader-leading', LEADINGS[s.lineHeight]);
            if (s.theme === 'auto') { root.removeAttribute('data-theme'); }
            else { root.setAttribute('data-theme', s.theme); }
            if (s.quoteStyle === 'italic') { root.setAttribute('data-quotes', 'italic'); }
            else { root.removeAttribute('data-quotes'); }
            // This page's own switch: `THUMBS` names it, so one attribute follows one field
            // whichever page this is. Baked into the markup too (see `themeAttribute`) so the
            // first paint is right before this script runs.
            if (s[THUMBS] === 'off') { root.setAttribute('data-thumbs', 'off'); }
            else { root.removeAttribute('data-thumbs'); }
            window.readerRevealThumbs();
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
            readerPost('readerSettings', s);
          }
          // How the host hands over settings merged in from another device: adopt and
          // redraw, but do NOT save — they are already the stored state, and writing them
          // back would restamp this device as their newest author.
          window.readerApplySettings = function (next) {
            if (!next) { return; }
            s = next;
            apply();
          };
          // How the host hands over a recents list merged in from another device: rows of
          // {title, url}, newest first. Built with DOM APIs like the hidden-phrase rows —
          // titles are other sites' text and never take the markup path. Redrawn in place
          // rather than by re-rendering the page, so whatever is typed into the start
          // page's field survives a sync landing mid-sentence.
          window.readerSetRecents = function (rows) {
            recents.querySelectorAll('.recent, .recent-empty, #readerClear')
              .forEach(function (n) { n.remove(); });
            if (!rows || !rows.length) {
              var empty = document.createElement('p');
              empty.className = 'recent-empty';
              empty.textContent = 'No recent articles';
              recents.appendChild(empty);
              return;
            }
            rows.forEach(function (entry) {
              var row = document.createElement('button');
              row.className = 'recent';
              row.dataset.url = entry.url;
              var title = document.createElement('span');
              title.className = 'recent-title';
              title.textContent = entry.title;
              row.appendChild(title);
              var host = '';
              try { host = new URL(entry.url).hostname; } catch (err) {}
              if (host) {
                var line = document.createElement('span');
                line.className = 'recent-host';
                line.textContent = host;
                row.appendChild(line);
              }
              recents.appendChild(row);
            });
            var clear = document.createElement('button');
            clear.id = 'readerClear';
            clear.textContent = 'Clear history';
            recents.appendChild(clear);
          };
          // The collapsing bottom-right chrome. The toggle is absent in the roomy layout
          // and on the pages whose chrome is a single button, so everything below checks.
          //
          // Showing and hiding walks the buttons and writes the state on each one. Two
          // earlier versions set a single attribute on an ancestor — `.reader-chrome`, then
          // `<html>` — and let one CSS rule reach the seven descendants. Both left buttons
          // painted after a collapse until an unrelated resize forced the recalculation,
          // reliably the first and last of the list. Writing the attribute to each element
          // cannot half-apply, and it costs seven attribute writes per toggle.
          //
          // The buttons are looked up once, from the ids the stylesheet uses, and a page
          // that never rendered one simply drops out of the list.
          var chromeToggle = document.getElementById('readerChromeToggle');
          var chromeButtons = \(HTML.jsString(stackButtonIDs.joined(separator: " ")))
            .split(' ')
            .map(function (id) { return document.getElementById(id); })
            .filter(Boolean);
          function setChromeOpen(open) {
            if (!chromeToggle) { return; }
            chromeButtons.forEach(function (b) {
              if (open) { b.setAttribute('\(chromeOpenAttr)', 'true'); }
              else { b.removeAttribute('\(chromeOpenAttr)'); }
            });
            chromeToggle.setAttribute('aria-expanded', String(open));
            chromeToggle.setAttribute('aria-label',
              open ? 'Hide reader controls' : 'Show reader controls');
          }
          // The toggle's own ARIA state is the record: it is set on the same line as the
          // buttons, and it is what a screen reader is already being told.
          function chromeIsOpen() {
            return !!chromeToggle && chromeToggle.getAttribute('aria-expanded') === 'true';
          }
          // Focus a chrome button, or the toggle when that button has no box to take it.
          // Opening a popover collapses the stack, so on a compact viewport every button
          // that can open one is `display: none` by the time the panel is dismissed — and
          // `focus()` on a display-less element is a no-op that leaves <body> focused, which
          // is the fall-through the two call sites exist to prevent. Asked as "does it have
          // boxes?" rather than by re-testing the breakpoint here: the collapse is a CSS
          // fact, and the script would only be keeping a second copy of it.
          function focusChrome(btn) {
            if (btn.getClientRects().length) { btn.focus(); return; }
            if (chromeToggle) { chromeToggle.focus(); }
          }
          // Opens one popover and closes the rest; `null` closes everything.
          function setOpen(which) {
            popovers.forEach(function (p) {
              var open = p.panel === which;
              p.panel.hidden = !open;
              p.btn.setAttribute('aria-expanded', String(open));
            });
            // A panel fills the screen above the toggle, so the column of buttons that
            // opened it would only be in the way. One thing on screen at a time.
            if (which) { setChromeOpen(false); }
            // Rows that were behind a closed panel have their thumbnails withheld until
            // here, so opening one is what asks the publishers for its images.
            if (which) { window.readerRevealThumbs(); }
          }
          if (chromeToggle) {
            chromeToggle.addEventListener('click', function () {
              // Pressing it while a panel is open means "give me the controls back": the
              // document handler below has already closed the panel by this point.
              setChromeOpen(!chromeIsOpen());
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
            // Hiding runs on every page that has an article; only the drawing below needs
            // the panel. The button, its badge and the list are one markup block, so one
            // check covers all three.
            if (!hiddenList) { return; }
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
              h.className = 'panel-group' + (extra ? ' ' + extra : '');
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
                readerPost('readerUnhide', phrase);
              });
              row.appendChild(text);
              if (count) { row.appendChild(chip); }
              row.appendChild(remove);
              hiddenList.appendChild(row);
            }
          };
          popovers.forEach(function (p) {
            p.btn.addEventListener('click', function () {
              setOpen(p.panel.hidden ? p.panel : null);
            });
          });
          // A row hands its URL to the host, which re-validates it against the app's domain
          // scope before navigating — the same path an incoming link takes. One listener for
          // both of the panel's lists: a suggested row is a recents row.
          if (recents) {
            var recentsList = document.getElementById('readerRecentsList');
            recents.addEventListener('click', function (e) {
              if (e.target.closest('#readerClear')) {
                // Removing the button detaches the click target, so the document-level
                // close handler would see a node outside .reader-controls and hide the
                // panel — hiding the empty state we're about to show. Stop it here.
                e.stopPropagation();
                // Empty the recents list in place — the host clears the stored list. Scoped
                // to that container, so the suggested group below it is left alone.
                recentsList.textContent = '';
                recentsList.removeAttribute('class');
                recentsList.insertAdjacentHTML('beforeend', window.readerEmptyRecents);
                e.target.closest('#readerClear').remove();
                // The button the user just activated is gone, and the panel stays open to
                // show the empty state — so focus has to go somewhere deliberate, or it
                // falls to <body> and the next Tab restarts at the top of the document.
                focusChrome(recentsBtn);
                readerPost('readerClear', '');
                return;
              }
              var row = e.target.closest('button[data-url]');
              if (!row) { return; }
              setOpen(null);
              readerPost('readerOpen', row.dataset.url);
            });
          }
          // The panel's second group: what to read next, so finishing an article doesn't
          // mean going home first (#33). Delivered by the host long after the page — or
          // never, which is why the group ships hidden.
          //
          // Plain rows, unlike the start page's: More/Less/Block are gated to that page,
          // three icon buttons don't fit a 280px row, and this page already carries its own
          // rating pair for the article on screen. Defined only where the container exists,
          // so the start page's richer implementation of the same host call is never
          // shadowed by this one, whatever order the scripts run in.
          var suggested = document.getElementById('readerSuggested');
          var suggestedList = document.getElementById('readerSuggestedList');
          if (suggested && suggestedList) {
            window.readerSetSuggestions = function (items) {
              var rows = (items || []).slice(0, \(popoverSuggestions));
              suggestedList.textContent = '';
              if (!rows.length) { suggested.hidden = true; return; }
              // Same rule as every other list: a column only where this one brought images.
              var thumbs = rows.some(function (item) { return !!item.image; });
              rows.forEach(function (item) {
                var row = document.createElement('button');
                row.className = 'recent';
                row.type = 'button';
                row.dataset.url = item.url;
                if (thumbs && item.image) {
                  var thumb = document.createElement('img');
                  thumb.className = 'recent-thumb';
                  thumb.alt = '';
                  thumb.loading = 'lazy';
                  thumb.referrerPolicy = 'no-referrer';
                  thumb.dataset.src = item.image;
                  thumb.onerror = function () {
                    thumb.insertAdjacentHTML('afterend', window.readerThumbPlaceholder);
                    thumb.remove();
                  };
                  row.appendChild(thumb);
                } else if (thumbs) {
                  row.insertAdjacentHTML('afterbegin', window.readerThumbPlaceholder);
                }
                // Titles and outlet names come from other people's feeds: text, never markup.
                var title = document.createElement('span');
                title.className = 'recent-title';
                title.textContent = item.title;
                var source = document.createElement('span');
                source.className = 'recent-host';
                source.textContent = item.source || '';
                row.appendChild(title);
                row.appendChild(source);
                suggestedList.appendChild(row);
              });
              suggestedList.classList.toggle('has-thumbs', thumbs);
              // Unhide first: the reveal withholds a src while the row is still behind a
              // `hidden` ancestor. The panel itself may well be closed, in which case
              // `setOpen` reveals these when it is opened.
              suggested.hidden = false;
              if (window.readerRevealThumbs) { window.readerRevealThumbs(); }
            };
          }
          document.addEventListener('click', function (e) {
            if (!e.target.closest('.reader-controls')) { setOpen(null); }
            // The stack dismisses on the same gesture, keyed one level out: the toggle sits
            // beside `.reader-controls`, not inside it, and pressing it must not be read as
            // a tap outside itself.
            if (!e.target.closest('.reader-chrome')) { setChromeOpen(false); }
          });
          document.addEventListener('keydown', function (e) {
            if (e.key !== 'Escape') { return; }
            // Return focus to the button that opened the popover being dismissed — or to
            // the toggle, since dismissing is also what collapsed that button away.
            var open = popovers.filter(function (p) { return !p.panel.hidden; })[0];
            if (open) { setOpen(null); focusChrome(open.btn); return; }
            // Nothing open but the stack: close it and hand focus back to the toggle, or
            // Escape would leave focus on a button that has just become invisible.
            if (chromeIsOpen()) { setChromeOpen(false); chromeToggle.focus(); }
          });
          // Like / dislike the article being read. Present only on the reader page; the
          // host owns the toggle, and calls back with the rating now in force so the two
          // buttons can never both read as pressed.
          var moreBtn = document.getElementById('readerMoreBtn');
          var lessBtn = document.getElementById('readerLessBtn');
          if (moreBtn && lessBtn) {
            var rate = function (direction) {
              readerPost('readerRate', direction);
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
