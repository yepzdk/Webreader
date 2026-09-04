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
        <meta name="viewport" content="width=device-width, initial-scale=1">
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
            max-width: 34rem; margin: 0 auto;
            /* Mobile first. A phone has no room to spend 18vh above the title, and the side
               padding has to clear a landscape notch as well as give the text room. Both
               grow at 34rem, where the measure stops being the constraint.
               The base top padding clears the chrome for the one case that still has it at
               the top: a pointer in a window narrower than the breakpoint. */
            padding-top: 56px;
            padding-bottom: 48px;
            padding-left: max(16px, env(safe-area-inset-left, 0px));
            padding-right: max(16px, env(safe-area-inset-right, 0px));
          }
          @media (min-width: 34rem) {
            main {
              padding-top: 18vh; padding-bottom: 64px;
              padding-left: max(24px, env(safe-area-inset-left, 0px));
              padding-right: max(24px, env(safe-area-inset-right, 0px));
            }
          }
          /* Last, so it wins at every width. On a compact viewport the chrome is a floating
             column in the bottom-right corner: nothing sits at the top but the progress
             hairline, so the headroom goes back to what the content wants — and the foot has
             to clear the toggle, which ends 58px up. Keyed on the same condition the chrome
             is, because it is the same fact about the layout. */
          @media \(ReaderChrome.compactViewport) {
            main {
              padding-top: 32px;
              padding-bottom: calc(78px + env(safe-area-inset-bottom, 0px));
            }
          }
          /* The front door — title and URL field — stays narrow and centred whatever the
             window does; only the lists below it spread out. */
          .intro { max-width: 34rem; margin: 0 auto; }
          .lists { display: grid; grid-template-columns: 1fr; gap: 0 32px; }
          /* Grid children default to min-width:auto, which refuses to shrink and breaks the
             ellipsis on long titles. */
          .lists > * { min-width: 0; }
          @media (min-width: 60rem) {
            main { max-width: 62rem; padding-top: 12vh; }
            .lists { grid-template-columns: 1fr 1fr; }
            /* Both columns start level: the recents heading has no top margin to fight. */
            .lists > *:first-child .section { margin-top: 28px; }
          }
          h1 {
            font-size: 22px; font-weight: 600; letter-spacing: -0.01em;
            margin: 0 0 20px; text-align: center;
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
          button[type="submit"] {
            padding: 9px 16px; font-family: inherit; font-size: 14px;
            color: #fff; background: var(--accent);
            border: 1px solid var(--accent); border-radius: 6px; cursor: pointer;
          }
          button[type="submit"]:hover { filter: brightness(1.08); }
          /* Touch: both controls reach the 44px floor, and the field's text goes to 16px.
             The size is not cosmetic — mobile Safari zooms the whole page in on focusing an
             input under 16px, which throws the layout off and needs a pinch to undo. */
          @media (pointer: coarse) {
            #url { padding: 12px 12px; font-size: 16px; min-height: 44px; }
            button[type="submit"] { padding: 12px 18px; font-size: 16px; min-height: 44px; }
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
          /* More/Less/Block on a suggested row. Visible by default and *hidden* only where
             a pointer can hover — the inverse of how this was written, and the reason it
             was written that way is the reason it had to change: on a touch screen there is
             no hover, so `opacity: 0` made three working controls permanently invisible and
             unreachable. `:focus-within` already covered the keyboard; nothing covered a
             finger. Where hover does exist the behaviour is unchanged. */
          .row-actions {
            flex: none; display: flex; gap: 2px; padding-right: 4px;
            transition: opacity 120ms ease;
          }
          @media (hover: hover) {
            .row-actions { opacity: 0; }
            .suggestion:hover .row-actions,
            .row-actions:focus-within { opacity: 1; }
          }
          @media (prefers-reduced-motion: reduce) { .row-actions { transition: none; } }
          .row-action {
            display: flex; padding: 4px; border: 0; border-radius: 4px;
            background: transparent; color: var(--muted); cursor: pointer;
          }
          .row-action:hover { color: var(--fg); background: var(--border); }
          .row-action svg { display: block; }
          /* The 21px icon box is a fine pointer target and a poor finger one; on touch it
             reaches the same floor as every other control, and the row grows to fit. */
          @media (pointer: coarse) {
            .row-action { padding: 11px; }
          }
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
              min-height: 44px; padding: 4px 2px;
            }
          }
          \(ReaderChrome.indent(ReaderChrome.controlsCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.backdropCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.chromeCSS(platform: platform), by: 10))
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
                                                             platform: platform), by: 10))
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
              // Row controls come first: they sit inside the row, and clicking one must not
              // also open the article.
              var control = e.target.closest('.row-action');
              if (control) {
                var suggestion = control.closest('.suggestion');
                var host = suggestion.dataset.host;
                var kind = control.dataset.action;
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
                return;
              }
              var row = e.target.closest('.recents-inline button[data-url], .suggestions button[data-url]');
              if (!row) { return; }
              post('readerOpen', row.dataset.url);
            });
            // Lucide-style line icons: thumbs-up, thumbs-down, and the same X the other
            // remove controls use. Markup is ours, never feed text.
            var ICON_MORE = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/></svg>';
            var ICON_LESS = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 14V2"/><path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/></svg>';
            var ICON_BLOCK = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>';

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

                var actions = document.createElement('div');
                actions.className = 'row-actions';
                actions.appendChild(action('more', 'More like this', ICON_MORE));
                actions.appendChild(action('less', 'Less like this', ICON_LESS));
                if (item.source) {
                  actions.appendChild(action('block', 'Block ' + item.source, ICON_BLOCK));
                }
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
