import Foundation


/// Builds the start page shown at launch and via Home. Pure (no AppKit/WebKit) so it's
/// unit-testable. Shares `OfflineFallback`'s visual language and follows light/dark.
public enum StartPage {
    /// The built-in page a handler-only app opens to. It's the app's entire front door, so
    /// besides naming the app it offers everything needed to start reading: a URL field
    /// (with the ⇧⌘O shortcut as a hint), the recents list, and the appearance controls —
    /// the same chrome as the reader page, reading the same persisted settings (#91).
    public static func html(appName: String,
                            settings: ReaderSettings = ReaderSettings(),
                            history: ReaderHistory = ReaderHistory(),
                            hidden: HiddenPhrases = HiddenPhrases()) -> String {
        let name = HTML.escape(appName)
        let sans = ReaderSettings.FontFamily.sans.css
        // Recents are listed inline here rather than tucked in the popover: this page has
        // the whole window and nothing competing for it, and picking up where you left off
        // is the most likely reason you're looking at it.
        let recentsList = history.entries.isEmpty
            ? """
            <p class="hint empty">No articles yet. Route links here from your browser picker
                  (e.g. Choosy), or open one from the command line with <code>open</code>.</p>
            """
            : """
            <h2 class="section">Recent articles</h2>
                  <div class="recents-inline">
                    \(ReaderChrome.indent(ReaderChrome.recentsRows(history), by: 8))
                  </div>
            """
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings))>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(name)</title>
        <style>
          \(ReaderChrome.indent(ReaderChrome.themeCSS(settings), by: 10))
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
            padding: 18vh 24px 64px;
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
          .empty { margin-top: 36px; }
          #suggested[hidden], .empty-suggestions[hidden] { display: none; }
          /* Suggested rows reuse the recents row markup, so they inherit its styling — the
             second line names the article's own outlet. */
          .empty-suggestions { text-align: left; margin-top: 10px; }
          .link {
            padding: 0; border: 0; background: none; cursor: pointer;
            font: inherit; color: var(--accent); text-decoration: underline;
          }
          /* A quiet way into Settings from the page whose content it governs. */
          #startSettings {
            position: fixed; bottom: 14px; left: 14px;
            padding: 5px 10px; font-family: inherit; font-size: 12px;
            color: var(--muted); background: var(--bg);
            border: 1px solid var(--border); border-radius: 6px; cursor: pointer;
          }
          #startSettings:hover { color: var(--fg); }
          \(ReaderChrome.indent(ReaderChrome.controlsCSS(), by: 10))
        </style>
        </head>
        <body>
          \(ReaderChrome.indent(ReaderChrome.controls(history: history), by: 2))
          <button id="startSettings" type="button">Settings</button>
          <main>
            <h1>\(name)</h1>
            <form id="open">
              <input id="url" type="text" inputmode="url" autocomplete="off"
                     autocapitalize="off" spellcheck="false" autofocus
                     aria-label="Address to open" placeholder="Paste or type a URL">
              <button type="submit">Open</button>
            </form>
            <p class="hint">or press <kbd>⇧⌘O</kbd> to open a copied link</p>
            <p id="error" hidden role="alert">That doesn't look like a link this app can open.</p>
            \(recentsList)
            <!-- Filled by the host once the sources have been fetched and ranked; the page
                 renders (and is usable) long before that, and stays as-is if nothing comes. -->
            <section id="suggested" hidden>
              <h2 class="section">Suggested articles</h2>
              <div class="suggestions"></div>
              <p class="hint empty-suggestions" hidden>Nothing to suggest yet.
                <button type="button" class="link" id="suggestSettings">Add a source</button>
              </p>
            </section>
          </main>
          <script>
          \(ReaderChrome.indent(ReaderChrome.controlsScript(settings: settings, hidden: hidden), by: 10))
          (function () {
            var form = document.getElementById('open');
            var field = document.getElementById('url');
            var error = document.getElementById('error');
            form.addEventListener('submit', function (e) {
              e.preventDefault();
              var value = field.value.trim();
              if (!value) { field.focus(); return; }
              error.hidden = true;
              try { window.webkit.messageHandlers.readerOpenURL.postMessage(value); }
              catch (err) {}
            });
            // Typing again clears a previous rejection.
            field.addEventListener('input', function () { error.hidden = true; });
            // Called by the host when it refuses the address.
            window.readerURLRejected = function () {
              error.hidden = false;
              field.focus();
              field.select();
            };
            function post(name, body) {
              try { window.webkit.messageHandlers[name].postMessage(body); } catch (err) {}
            }
            // The inline recents list and the suggestions share the popover's row markup,
            // so they need the same click handling — the popover's own listener is scoped
            // to the popover.
            document.querySelector('main').addEventListener('click', function (e) {
              if (e.target.closest('#suggestSettings')) { post('readerOpenSettings', ''); return; }
              var row = e.target.closest('.recents-inline button[data-url], .suggestions button[data-url]');
              if (!row) { return; }
              post('readerOpen', row.dataset.url);
            });
            document.getElementById('startSettings').addEventListener('click', function () {
              post('readerOpenSettings', '');
            });

            // The host calls this once its sources are fetched and ranked — possibly never
            // (no sources, no network), which is why the section starts hidden. Rows are
            // built from text, never markup: the titles come from other people's feeds.
            window.readerSetSuggestions = function (items) {
              var section = document.getElementById('suggested');
              var list = section.querySelector('.suggestions');
              var empty = section.querySelector('.empty-suggestions');
              list.textContent = '';
              (items || []).forEach(function (item) {
                var row = document.createElement('button');
                row.className = 'recent';
                row.type = 'button';
                row.dataset.url = item.url;
                var title = document.createElement('span');
                title.className = 'recent-title';
                title.textContent = item.title;
                var source = document.createElement('span');
                source.className = 'recent-host';
                source.textContent = item.source || '';
                row.appendChild(title);
                row.appendChild(source);
                list.appendChild(row);
              });
              empty.hidden = (items || []).length > 0;
              section.hidden = false;
            };
          })();
          </script>
        </body>
        </html>
        """
    }
}
