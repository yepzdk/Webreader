import Foundation


/// Builds the start page shown at launch and via Home. Pure (no AppKit/WebKit) so it's
/// unit-testable. Shares `OfflineFallback`'s visual language and follows light/dark.
public enum StartPage {
    /// The page's two platform-dependent sentences: the chord that opens a copied link,
    /// and how links get here at all before anything has been read.
    ///
    /// This is page copy, so it lives here rather than on `Platform`. The empty-recents
    /// line names *this app's* command-line form and its own registration as the system's
    /// link handler — nothing another program on the same OS would word the same way —
    /// while `Platform` stays what its own comment says it is: how a page renders on a
    /// given machine. What this does share with `Platform` is the reason for being a value
    /// rather than `#if os(Linux)`: the copy must follow the machine the page is
    /// *displayed* on, and both variants have to stay assertable from whichever OS runs
    /// the suite.
    ///
    /// Both strings are ours rather than user input and one of them carries markup, so
    /// they are written already-escaped here and never passed through `HTML.escape`.
    private struct Copy {
        /// The clipboard-open chord, as a single `<kbd>` — the treatment this hint has
        /// always used, because a chord is one key cap and not three. Nil on a host that
        /// binds no chord, where the whole hint paragraph is dropped rather than printed
        /// with an empty key cap.
        let openChord: String?
        /// The empty-recents paragraph's inner HTML. Its line break and the continuation
        /// indent are part of the macOS page's bytes, which a regression test pins, so the
        /// wrap stays where it was instead of being reflowed here.
        let emptyRecents: String

        init(_ platform: Platform) {
            switch platform {
            case .macOS:
                openChord = "⇧⌘O"
                emptyRecents = """
                    No articles yet. Route links here from your browser picker
                          (e.g. Choosy), or open one from the command line with <code>open</code>.
                    """
            case .linux:
                // No application is named: the browser chooser is whichever handler dialog
                // the desktop puts up, and this app appears in it because of its .desktop
                // file. Choosy is a Mac app, and no Linux equivalent is universal enough to
                // name — "browser chooser" is both true and stable. `webreader <url>` is
                // the command the Linux host actually installs.
                openChord = "Ctrl+Shift+O"
                emptyRecents = """
                    No articles yet. Route links here from your browser chooser,
                          or open one from the command line with <code>webreader &lt;url&gt;</code>.
                    """
            case .iOS:
                // The share sheet is how a link actually arrives on iOS, and it is the one
                // route a reader can be told to look for by name. No chord and no command
                // line, so the paste field above is the only other way in and needs no
                // hint of its own.
                openChord = nil
                emptyRecents = """
                    No articles yet. Share a link to this app from Safari or anywhere
                          else, or paste one above.
                    """
            case .android:
                // "Share menu" rather than "share sheet": Android's own wording, and the
                // chooser is what an intent filter puts this app into.
                openChord = nil
                emptyRecents = """
                    No articles yet. Share a link to this app from your browser or
                          anywhere else, or paste one above.
                    """
            }
        }
    }

    /// The built-in page a handler-only app opens to. It's the app's entire front door, so
    /// besides naming the app it offers everything needed to start reading: a URL field
    /// (with the clipboard-open chord as a hint), the recents list, and the appearance
    /// controls — the same chrome as the reader page, reading the same persisted
    /// settings (#91).
    ///
    /// `platform` selects the font stacks and the page's platform-dependent copy (see
    /// `Copy`), defaulting to macOS so the AppKit host needs no argument; a GTK host
    /// passes `.linux`. `palette` is the desktop palette for `Theme.auto`, nil by default
    /// so the `prefers-color-scheme` fallback stands.
    public static func html(appName: String,
                            settings: ReaderSettings = ReaderSettings(),
                            history: ReaderHistory = ReaderHistory(),
                            platform: Platform = .macOS,
                            palette: ReaderPalette? = nil) -> String {
        let name = HTML.escape(appName)
        let sans = platform.sansStack
        // The shared touch floor, bound once so the rules below read as CSS.
        let touchTarget = ReaderChrome.touchTarget
        let copy = Copy(platform)
        // Only where a chord exists to name. On a touch host the field's own placeholder
        // is the whole instruction, and a hint naming a key nobody can press is worse
        // than none — the same rule the Linux copy above already follows.
        let openHint = copy.openChord.map {
            "\n            <p class=\"hint\">or press <kbd>\(HTML.escape($0))</kbd> "
                + "to open a copied link</p>"
        } ?? ""
        // Autofocus is a desktop courtesy and a touch hostility: on a phone it throws the
        // soft keyboard over the recents list before the page has been read, so the field
        // is focused only where focusing it costs the reader no screen.
        let autofocus = platform.hasKeyboardCommands ? " autofocus" : ""
        // Recents are listed inline here rather than tucked in the popover: this page has
        // the whole window and nothing competing for it, and picking up where you left off
        // is the most likely reason you're looking at it.
        // A list shows thumbnails only when something in it has an image; otherwise every row
        // would carry an empty slot and the list would look worse than it did before #25.
        let hasThumbs = history.entries.contains { !($0.image ?? "").isEmpty }
        let recentsList = history.entries.isEmpty
            ? """
            <p class="hint empty">\(copy.emptyRecents)</p>
            """
            : """
            <h2 class="section">Recent articles</h2>
                  <div class="recents-inline\(hasThumbs ? " has-thumbs" : "")">
                    \(ReaderChrome.indent(ReaderChrome.recentsRows(history, thumbnails: hasThumbs), by: 8))
                  </div>
                  <p class="clear-history">
                    <button type="button" class="link" id="startClear">Clear history</button>
                  </p>
            """
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings, thumbnails: .startPage))>
        <head>
        <meta charset="utf-8">
        \(ReaderChrome.viewportMeta)
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="WebReader Start">
        <title>\(name)</title>
        \(ReaderChrome.transportScript(platform: platform))
        <style>
          \(ReaderChrome.indent(ReaderChrome.themeCSS(settings, platform: platform,
                                                      palette: palette), by: 10))
          * { box-sizing: border-box; }
          html, body { height: 100%; margin: 0; }
          body {
            background: var(--bg);
            color: var(--fg);
            font: 15px/1.5 \(sans);
            -webkit-font-smoothing: antialiased;
          }
          main {
            max-width: var(--reader-width); margin: 0 auto;
            /* Mobile first. A phone has no room to spend 18vh above the title, and the side
               padding has to clear a landscape notch as well as give the text room. Both
               grow at 34rem, where the measure stops being the constraint.
               The base top padding clears the chrome for the one case that still has it at
               the top: a pointer in a window narrower than the breakpoint. */
            padding-top: 56px;
            padding-bottom: 48px;
            padding-left: max(16px, var(--safe-left));
            padding-right: max(16px, var(--safe-right));
          }
          @media (min-width: 34rem) {
            main {
              padding-top: 18vh; padding-bottom: 64px;
              padding-left: max(24px, var(--safe-left));
              padding-right: max(24px, var(--safe-right));
            }
          }
          /* Last, so it wins at every width. On a compact viewport the chrome is a floating
             column in the bottom-right corner: nothing sits at the top but the progress
             hairline, so the headroom goes back to what the content wants — plus whatever a
             notch or a Dynamic Island takes, since the page is drawn edge to edge. The foot
             has to clear the toggle, which ends 58px up. Keyed on the same condition the
             chrome is, because it is the same fact about the layout. */
          @media \(ReaderChrome.compactViewport) {
            main {
              padding-top: \(ReaderChrome.inset(32, "top"));
              padding-bottom: \(ReaderChrome.inset(78, "bottom"));
            }
          }
          /* The front door — title and URL field — stays narrow and centred whatever the
             window does; only the lists below it spread out. Its measure is the reader's own
             column width, so Narrow/Normal/Wide mean something here too (#45 follow-up):
             the page a reader lands on answers to the same controls the article does. */
          .intro { max-width: var(--reader-width); margin: 0 auto; }
          .lists { display: grid; grid-template-columns: 1fr; gap: 0 32px; }
          /* Grid children default to min-width:auto, which refuses to shrink and breaks the
             ellipsis on long titles. */
          .lists > * { min-width: 0; }
          /* The reader's chosen order (`startPageOrder`). `order` rather than rearranging the
             nodes: the suggestions arrive from the host long after this document is written
             and the recents column rebuilds itself when it is cleared, so a DOM order the two
             had to agree on would be one more thing for either of them to get wrong. Both
             layouts honour it — the stack below 60rem and the two columns above it. */
          :root[data-order="suggestionsFirst"] #suggested { order: -1; }
          @media (min-width: 60rem) {
            main { max-width: 62rem; padding-top: 12vh; }
            .lists { grid-template-columns: 1fr 1fr; }
            /* Both columns start level: the recents heading has no top margin to fight. */
            .lists > *:first-child .section { margin-top: 28px; }
            /* `order` moves the columns and `:first-child` cannot follow it, so the leading
               column's tighter heading is moved by hand when the order is reversed. */
            :root[data-order="suggestionsFirst"] .recents-column .section { margin-top: 36px; }
            :root[data-order="suggestionsFirst"] #suggested .section { margin-top: 28px; }
          }
          /* The page's own words follow the reader's typeface and size, because they are the
             same reader looking at the same screen: before this, five of the seven controls
             did nothing here and only the theme and the highlight showed any effect at all.

             The chrome does not follow: buttons, hints and section labels stay in the sans
             stack at their fixed sizes. Serif is a choice about prose, and a 12px serif
             button is a worse button — the same split the reader makes, where the article
             takes the setting and the controls around it do not. */
          h1 {
            font-family: var(--reader-font);
            font-size: calc(var(--reader-size) * 1.3); font-weight: 600;
            letter-spacing: -0.01em; margin: 0 0 20px; text-align: center;
          }
          /* The lists are the reading on this page, so they take the size, the face and the
             leading. They were pinned at 12px, which is smaller than anything the reader can
             choose and the first thing a reader who wants larger text notices. */
          .recents-inline .recent, .suggestions .recent {
            font-size: calc(var(--reader-size) * 0.82);
            line-height: var(--reader-leading);
          }
          .recents-inline .recent-title, .suggestions .recent-title {
            font-family: var(--reader-font);
          }
          .recents-inline .recent-host, .suggestions .recent-host {
            font-size: calc(var(--reader-size) * 0.72);
          }
          /* URL entry — the primary action, so it leads. */
          form { display: flex; gap: 8px; margin: 0 0 8px; }
          #url {
            flex: 1; min-width: 0; padding: 9px 11px;
            font-family: inherit; font-size: 14px;
            color: var(--fg); background: var(--bg);
            border: 1px solid var(--border); border-radius: 6px;
          }
          #url:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
          #url::placeholder { color: var(--muted); }
          /* Outlined, like every other control the accent touches. It was a filled slab
             with a white label, which is legible right up until the accent is the page's
             own text colour: on black with the highlight following the text, "Open" was
             white on near-white. One rule for all of them — the colour goes on the
             background it was measured against, never underneath a label. */
          button[type="submit"] {
            padding: 9px 16px; font-family: inherit; font-size: 14px;
            color: var(--accent); background: transparent;
            border: 1px solid var(--accent); border-radius: 6px; cursor: pointer;
          }
          button[type="submit"]:hover { background: var(--surface); }
          /* Touch: both controls reach the 44px floor, and the field's text goes to 16px.
             The size is not cosmetic — mobile Safari zooms the whole page in on focusing an
             input under 16px, which throws the layout off and needs a pinch to undo. */
          @media (pointer: coarse) {
            #url { padding: 12px 12px; font-size: 16px; min-height: \(touchTarget)px; }
            button[type="submit"] {
              padding: 12px 18px; font-size: 16px; min-height: \(touchTarget)px;
            }
          }
          .hint { color: var(--muted); font-size: 12px; margin: 0; text-align: center; }
          .hint code {
            font-family: ui-monospace, Menlo, monospace; font-size: 11px;
            padding: 1px 4px; background: var(--surface); border-radius: 3px;
          }
          kbd {
            font-family: inherit; font-size: 11px; padding: 1px 5px;
            border: 1px solid var(--border); border-radius: 4px; background: var(--surface);
          }
          /* Shown by the host when a typed URL is rejected. */
          #error {
            margin: 8px 0 0; text-align: center; font-size: 12px; color: var(--accent);
          }
          #error[hidden] { display: none; }
          .section {
            font-size: 11px; font-weight: 600; letter-spacing: 0.04em;
            text-transform: uppercase; color: var(--muted);
            margin: 36px 0 8px; padding-bottom: 8px;
            border-bottom: 1px solid var(--border);
          }
          .recents-inline, .suggestions { display: flex; flex-direction: column; }
          /* Two lines here, unlike the narrow recents popover: a single line cuts most Danish
             headlines before they say what the article is about. Still clamped — a row is a
             glance, not the article. */
          .recents-inline .recent-title, .suggestions .recent-title {
            white-space: normal;
            display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2;
          }
          .empty { margin-top: 36px; }
          #suggested[hidden], .empty-suggestions[hidden] { display: none; }
          /* Suggested rows reuse the recents row markup, so they inherit its styling — the
             second line names the article's own outlet. */
          .empty-suggestions { text-align: left; margin-top: 10px; }
          /* A suggested row is the recents row plus its controls, so the row itself becomes
             the flex container and the button inside it keeps the click target. */
          .suggestion { display: flex; align-items: center; border-radius: 5px; }
          .suggestion:hover { background: var(--surface); }
          .suggestion .recent { flex: 1; min-width: 0; }
          .suggestion .recent:hover { background: transparent; }
          /* More/Less/Block/Hide on a suggested row, and the one button that stands in for
             them.

             Behind the button on every viewport, which is the third and last position this
             took. They were revealed on hover, which made them invisible and unreachable on
             a touch screen; then visible by default and collapsed on a narrow one, which
             fixed the phone and left a desktop row carrying four controls it was not asked
             for. Four icons beside every title is a toolbar per row: it reads as clutter,
             it competes with the headline it belongs to, and it spends the width the
             headline wanted. One quiet button per row asks nothing until it is pressed.

             Tapping it swaps it for the controls rather than adding them beside it, so an
             open row is exactly as wide as every other row and only one row at a time
             spends its title on buttons. */
          .row-actions {
            flex: none; display: none; gap: 2px; padding-right: 4px;
          }
          .row-action {
            display: flex; padding: 4px; border: 0; border-radius: 4px;
            background: transparent; color: var(--muted); cursor: pointer;
          }
          .row-action:hover { color: var(--fg); background: var(--border); }
          .row-action svg { display: block; }
          /* The 21px icon box is a fine pointer target and a poor finger one; on touch it
             reaches the same floor as every other control, and the row grows to fit. The
             floor, not padding around the icon: 11px each side computes to 35px, which is
             neither the 44px this claims nor any other control's size. */
          @media (pointer: coarse) {
            .row-action {
              min-height: \(touchTarget)px; min-width: \(touchTarget)px;
              align-items: center; justify-content: center;
            }
          }
          .row-menu {
            display: flex; flex: none; padding: 4px; margin-right: 4px;
            border: 0; border-radius: 4px;
            background: transparent; color: var(--muted); cursor: pointer;
          }
          .row-menu:hover { color: var(--fg); background: var(--border); }
          .row-menu svg { display: block; }
          @media (pointer: coarse) {
            .row-menu {
              min-height: \(touchTarget)px; min-width: \(touchTarget)px;
              align-items: center; justify-content: center;
            }
          }
          /* Open swaps the two: the menu goes, the controls arrive in its place. */
          .suggestion[data-actions="open"] .row-menu { display: none; }
          .suggestion[data-actions="open"] .row-actions { display: flex; }
          .link {
            padding: 0; border: 0; background: none; cursor: pointer;
            font: inherit; color: var(--accent); text-decoration: underline;
          }
          /* Clearing history sits under the list it clears — the reader page keeps its own
             copy inside the recents popover, since neither page ever shows the other's (#32).
             Muted rather than accented like "Add a source": it is the one destructive control
             on the page, and should not be the first thing the eye lands on. The underline
             comes back on hover and focus, and the padding takes the target to 24px — quiet
             is not the same as hard to hit (WCAG 2.5.8). */
          .clear-history { margin: 6px 0 0; font-size: 12px; }
          .clear-history .link { padding: 4px 2px; color: var(--muted); text-decoration: none; }
          .clear-history .link:hover, .clear-history .link:focus-visible {
            color: var(--fg); text-decoration: underline;
          }
          /* Touch: 24px is the WCAG 2.5.8 floor this was built to and a poor finger target.
             It stays visually quiet — same size type, same muted colour — and only the hit
             area grows, which is the whole point of the distinction. */
          @media (pointer: coarse) {
            .clear-history .link {
              display: inline-flex; align-items: center;
              min-height: \(touchTarget)px; padding: 4px 2px;
            }
          }
          \(ReaderChrome.indent(ReaderChrome.controlsCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.backdropCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.chromeCSS(platform: platform,
                                                       collapsible: true), by: 10))
          \(ReaderChrome.indent(ReaderChrome.toastCSS(platform: platform), by: 10))
        </style>
        </head>
        <body>
          \(ReaderChrome.backdrop())
          \(ReaderChrome.indent(ReaderChrome.chrome(
                nav: ReaderChrome.navSettings(),
                controls: ReaderChrome.controls(),
                collapsible: true), by: 2))
          <main>
            <div class="intro">
            <h1>\(name)</h1>
            <form id="open">
              <input id="url" type="text" inputmode="url" autocomplete="off"
                     autocapitalize="off" spellcheck="false"\(autofocus)
                     aria-label="Address to open" placeholder="Paste or type a URL">
              <button type="submit">Open</button>
            </form>\(openHint)
            <p id="error" hidden role="alert">That doesn't look like a link this app can open.</p>
            </div>
            <div class="lists">
            <div class="recents-column">
            \(recentsList)
            </div>
            <!-- Filled by the host once the sources have been fetched and ranked; the page
                 renders (and is usable) long before that, and stays as-is if nothing comes. -->
            <section id="suggested" hidden>
              <h2 class="section">Suggested articles</h2>
              <div class="suggestions"></div>
              <p class="hint empty-suggestions" hidden>Nothing to suggest yet.
                <button type="button" class="link" id="suggestSettings">Add a source</button>
              </p>
            </section>
            </div>
          </main>
          \(ReaderChrome.toastMarkup())
          <script>
          \(ReaderChrome.indent(ReaderChrome.controlsScript(settings: settings,
                                                             thumbnails: .startPage,
                                                             hidden: HiddenPhrases([]),
                                                             platform: platform,
                                                             hostedAccent: settings.theme == .auto
                                                                 && palette != nil), by: 10))
          \(ReaderChrome.indent(ReaderChrome.toastScript(), by: 10))
          // What the whole column falls back to once cleared — heading and list included, so
          // it is this page's own empty state rather than the popover's one-line
          // `readerEmptyRecents`. Ours, never feed text.
          window.readerEmptyColumn = \(HTML.jsString("<p class=\"hint empty\">\(copy.emptyRecents)</p>"));
          (function () {
            var form = document.getElementById('open');
            var field = document.getElementById('url');
            var error = document.getElementById('error');
            form.addEventListener('submit', function (e) {
              e.preventDefault();
              var value = field.value.trim();
              if (!value) { field.focus(); return; }
              error.hidden = true;
              readerPost('readerOpenURL', value);
            });
            // Typing again clears a previous rejection.
            field.addEventListener('input', function () { error.hidden = true; });
            // Called by the host when it refuses the address.
            window.readerURLRejected = function () {
              error.hidden = false;
              field.focus();
              field.select();
            };
            // `readerPost` is defined in <head>; this alias keeps the call sites below on
            // the short name they have always used.
            var post = window.readerPost;
            // The inline recents list and the suggestions share the popover's row markup,
            // so they need the same click handling — the popover's own listener is scoped
            // to the popover.
            document.querySelector('main').addEventListener('click', function (e) {
              if (e.target.closest('#suggestSettings')) { post('readerOpenSettings', ''); return; }
              // Clearing history: the host empties the store (and prunes the offline cache
              // with it), the page empties the column. A separate id from the popover's
              // #readerClear, which carries the popover's own styling and is handled by the
              // shared chrome script.
              if (e.target.closest('#startClear')) {
                // Ancestor of the button by construction, so no null to guard.
                var column = e.target.closest('.recents-column');
                column.textContent = '';
                column.insertAdjacentHTML('afterbegin', window.readerEmptyColumn);
                post('readerClear', '');
                // The button that was focused is gone. Say what happened — the offline copies
                // went too, which the list disappearing does not convey — and put focus on
                // the paragraph that replaced it rather than letting it fall to <body>.
                window.readerToast('History cleared, including saved copies.');
                var empty = column.querySelector('.empty');
                if (empty) { empty.tabIndex = -1; empty.focus(); }
                return;
              }
              // The row's own menu, where the three controls do not fit beside a title.
              var menu = e.target.closest('.row-menu');
              if (menu) {
                var open = menu.closest('.suggestion');
                // One row at a time: two open menus in a column read as one row with six
                // controls, and the second tap would land on the wrong article's opinion.
                open.parentElement.querySelectorAll('.suggestion[data-actions="open"]').forEach(function (other) {
                  if (other !== open) { closeRowMenu(other); }
                });
                var wasOpen = open.getAttribute('data-actions') === 'open';
                if (wasOpen) {
                  closeRowMenu(open);
                } else {
                  open.setAttribute('data-actions', 'open');
                  menu.setAttribute('aria-expanded', 'true');
                  // Focus follows the controls the tap revealed, so a keyboard reaches them
                  // without tabbing back through the row.
                  var first = open.querySelector('.row-action');
                  if (first) { first.focus(); }
                }
                return;
              }
              // Row controls come first: they sit inside the row, and clicking one must not
              // also open the article.
              var control = e.target.closest('.row-action');
              if (control) {
                var suggestion = control.closest('.suggestion');
                var host = suggestion.dataset.host;
                var kind = control.dataset.action;
                // Closing is the X's only job now. It used to be the block control's glyph,
                // where it read as "dismiss this menu" and did something rather harder to
                // undo — one tap from an outlet you never see again.
                if (kind === 'close') {
                  closeRowMenu(suggestion);
                  var reopen = suggestion.querySelector('.row-menu');
                  if (reopen) { reopen.focus(); }
                  return;
                }
                if (kind === 'block') {
                  suggestion.remove();
                  post('readerBlockHost', host);
                  window.readerToast('No more articles from ' + host + '.');
                  return;
                }
                post('readerTopicFeedback', { title: suggestion.dataset.title, direction: kind });
                window.readerToast(kind === 'more'
                  ? 'More articles like this from now on.'
                  : 'Fewer articles like this from now on.');
                // The opinion is registered and the row keeps its place; the menu has nothing
                // left to say, so it closes behind the answer.
                closeRowMenu(suggestion);
                return;
              }
              var row = e.target.closest('.recents-inline button[data-url], .suggestions button[data-url]');
              if (!row) { return; }
              post('readerOpen', row.dataset.url);
            });
            // Lucide-style line icons. Markup is ours, never feed text.
            var ICON_MORE = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/></svg>';
            var ICON_LESS = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 14V2"/><path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/></svg>';
            // ban, not an X: blocking an outlet is a decision about the list, and an X beside
            // two opinions reads as "close this" — which is now what the X actually does.
            var ICON_BLOCK = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg>';
            var ICON_CLOSE = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>';
            // The vertical ellipsis is this menu's alone — the reader's own chrome toggle took
            // the three-line mark, so "this row's options" and "the app's controls" cannot be
            // mistaken for each other.
            var ICON_MENU = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/></svg>';

            function action(kind, label, icon) {
              var button = document.createElement('button');
              button.className = 'row-action';
              button.type = 'button';
              button.dataset.action = kind;
              button.setAttribute('aria-label', label);
              button.setAttribute('title', label);
              button.innerHTML = icon;
              return button;
            }

            // Closes a row's menu and puts its own button back in charge of the state. One
            // routine because three paths close a menu — the X, an opinion that has been
            // registered, and opening a different row — and a half-closed menu is an
            // `aria-expanded` that lies to a screen reader.
            function closeRowMenu(suggestion) {
              suggestion.removeAttribute('data-actions');
              var toggle = suggestion.querySelector('.row-menu');
              if (toggle) { toggle.setAttribute('aria-expanded', 'false'); }
            }

            // The row's menu button. Only ever visible where the three controls would not
            // fit beside a title — see `.row-menu` in the stylesheet.
            function rowMenu(title) {
              var button = document.createElement('button');
              button.className = 'row-menu';
              button.type = 'button';
              button.setAttribute('aria-expanded', 'false');
              button.setAttribute('aria-label', 'Options for ' + title);
              button.innerHTML = ICON_MENU;
              return button;
            }

            // The host calls this once its sources are fetched and ranked — possibly never
            // (no sources, no network), which is why the section starts hidden. Rows are
            // built from text, never markup: the titles come from other people's feeds.
            window.readerSetSuggestions = function (items) {
              var section = document.getElementById('suggested');
              var list = section.querySelector('.suggestions');
              var empty = section.querySelector('.empty-suggestions');
              list.textContent = '';
              // Same rule as the server-rendered recents list: a column only where this batch
              // actually brought images.
              var thumbs = (items || []).some(function (item) { return !!item.image; });
              (items || []).forEach(function (item) {
                var wrap = document.createElement('div');
                wrap.className = 'suggestion';
                wrap.dataset.host = item.source || '';
                wrap.dataset.title = item.title;

                var row = document.createElement('button');
                row.className = 'recent';
                row.type = 'button';
                row.dataset.url = item.url;
                // The same thumbnail a recents row gets, and built the same way: the element
                // carries `data-src` only, so whether it ever fetches is decided in one place
                // (`readerRevealThumbs`, called below) rather than here.
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
                  // No image for this one, but the list has a column — fill the slot.
                  row.insertAdjacentHTML('afterbegin', window.readerThumbPlaceholder);
                }
                var title = document.createElement('span');
                title.className = 'recent-title';
                title.textContent = item.title;
                var source = document.createElement('span');
                source.className = 'recent-host';
                source.textContent = item.source || '';
                row.appendChild(title);
                row.appendChild(source);
                wrap.appendChild(row);
                wrap.appendChild(rowMenu(item.title));

                var actions = document.createElement('div');
                actions.className = 'row-actions';
                actions.appendChild(action('more', 'More like this', ICON_MORE));
                actions.appendChild(action('less', 'Less like this', ICON_LESS));
                if (item.source) {
                  actions.appendChild(action('block', 'Block ' + item.source, ICON_BLOCK));
                }
                // Last, so the way out sits where the X sat before — and now means it.
                actions.appendChild(action('close', 'Hide options', ICON_CLOSE));
                wrap.appendChild(actions);
                list.appendChild(wrap);
              });
              list.classList.toggle('has-thumbs', thumbs);
              empty.hidden = (items || []).length > 0;
              // Unhide before revealing: these rows were built after the appearance script
              // last ran, and the one function allowed to turn a data-src into a fetch
              // withholds it while the row is still behind a `hidden` ancestor.
              section.hidden = false;
              if (window.readerRevealThumbs) { window.readerRevealThumbs(); }
            };
          })();
          </script>
        </body>
        </html>
        """
    }
}
