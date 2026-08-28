import Foundation

/// The settings page: where suggestion sources live. Pure like the other generated pages,
/// sharing `ReaderChrome`'s palette and the start page's document shape.
///
/// Appearance is NOT here — it belongs in the Aa popover, next to the text it changes. This
/// page is the one thing that has nowhere else to live: a list of feeds, which is data the
/// user manages rather than a control they nudge while reading.
public enum SettingsPage {
    public static func html(appName: String,
                            settings: ReaderSettings = ReaderSettings(),
                            suggestions: SuggestionSettings = SuggestionSettings()) -> String {
        let name = HTML.escape(appName)
        let sans = ReaderSettings.FontFamily.sans.css
        let sourceRows = suggestions.sources.isEmpty
            ? "<p class=\"empty\">No sources. Suggestions stay empty until you add one.</p>"
            : suggestions.sources.map(row).joined(separator: "\n        ")
        // A language toggle only makes sense once two languages are in play; with one (or
        // none) declared there is nothing to choose between, so the section stays hidden.
        let languages = suggestions.availableLanguages
        let languageSection = languages.count < 2 ? "" : """
        <h2 class="section">Languages</h2>
              <p class="help">Only suggest articles in these languages.</p>
              <div class="langs">
                \(languages.map { code in
                    let checked = suggestions.languages?.contains(code) ?? true
                    return "<label class=\"lang\"><input type=\"checkbox\" value=\"\(HTML.escape(code))\""
                        + (checked ? " checked" : "") + "><span>\(HTML.escape(languageName(code)))</span></label>"
                }.joined(separator: "\n            "))
              </div>
        """
        // Only shown once something is blocked: an empty section on first run is noise, and
        // rows are added from the start page, not typed in here.
        let blocked = suggestions.blockedHosts.sorted()
        let blockedSection = blocked.isEmpty ? "" : """
        <section id="blockedSection">
                <h2 class="section">Blocked outlets</h2>
                <p class="help">Never suggested. Block an outlet from a suggested article on
                the start page.</p>
                <div id="blocked">
                  \(blocked.map(blockedRow).joined(separator: "\n              "))
                </div>
              </section>
        """
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings))>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="WebReader Settings">
        <title>Settings — \(name)</title>
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
          main { max-width: 34rem; margin: 0 auto; padding: 10vh 24px 64px; }
          h1 {
            font-size: 22px; font-weight: 600; letter-spacing: -0.01em;
            margin: 0 0 4px;
          }
          .lede { color: var(--muted); font-size: 13px; margin: 0 0 28px; }
          .section {
            font-size: 11px; font-weight: 600; letter-spacing: 0.04em;
            text-transform: uppercase; color: var(--muted);
            margin: 32px 0 8px; padding-bottom: 8px;
            border-bottom: 1px solid var(--border);
          }
          .help { color: var(--muted); font-size: 12px; margin: 0 0 12px; }
          .empty { color: var(--muted); font-size: 13px; margin: 0; padding: 10px 0; }
          /* Source rows: title over host, with the remove control at the trailing edge. */
          .source {
            display: flex; align-items: center; gap: 10px;
            padding: 10px 2px; border-bottom: 1px solid var(--border);
          }
          .source-text { flex: 1; min-width: 0; }
          .source-title {
            display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            font-size: 14px;
          }
          .source-host { display: block; margin-top: 1px; font-size: 12px; color: var(--muted); }
          .source-lang {
            flex: none; padding: 1px 6px; border: 1px solid var(--border); border-radius: 4px;
            font-size: 11px; color: var(--muted); text-transform: uppercase;
          }
          .source-remove {
            flex: none; display: flex; padding: 5px; border: 0; border-radius: 4px;
            background: transparent; color: var(--muted); cursor: pointer;
          }
          .source-remove:hover { color: var(--fg); background: var(--surface); }
          .source-remove svg { display: block; }
          form { display: flex; gap: 8px; margin: 16px 0 0; }
          #source {
            flex: 1; min-width: 0; padding: 9px 11px;
            font-family: inherit; font-size: 14px;
            color: var(--fg); background: var(--bg);
            border: 1px solid var(--border); border-radius: 6px;
          }
          #source:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
          #source::placeholder { color: var(--muted); }
          form button {
            padding: 9px 16px; font-family: inherit; font-size: 14px;
            color: #fff; background: var(--accent);
            border: 1px solid var(--accent); border-radius: 6px; cursor: pointer;
          }
          form button:hover { filter: brightness(1.08); }
          form button:disabled { opacity: 0.5; cursor: default; filter: none; }
          #error { margin: 8px 0 0; font-size: 12px; color: var(--accent); }
          #error[hidden] { display: none; }
          .langs { display: flex; flex-wrap: wrap; gap: 8px 18px; }
          .lang { display: flex; align-items: center; gap: 6px; font-size: 13px; cursor: pointer; }
          .lang input { accent-color: var(--accent); }
          .done {
            margin-top: 36px; padding: 8px 14px;
            font-family: inherit; font-size: 13px; color: var(--fg);
            background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
            cursor: pointer;
          }
          .done:hover { background: var(--surface); }
        </style>
        </head>
        <body>
          <main>
            <h1>Settings</h1>
            <p class="lede">Sources feed the suggestions on the start page.</p>

            <h2 class="section">Suggestion sources</h2>
            <p class="help">A feed address, or a site address to look one up on.</p>
            <div id="sources">
              \(ReaderChrome.indent(sourceRows, by: 8))
            </div>
            <form id="add">
              <input id="source" type="text" inputmode="url" autocomplete="off"
                     autocapitalize="off" spellcheck="false"
                     aria-label="Feed or site address" placeholder="https://example.com/rss">
              <button type="submit">Add</button>
            </form>
            <p id="error" hidden role="alert">No feed found at that address.</p>

            \(languageSection)

            \(blockedSection)

            <button class="done" id="done">Done</button>
          </main>
          <script>
          (function () {
            function post(name, body) {
              try { window.webkit.messageHandlers[name].postMessage(body); } catch (err) {}
            }
            var sources = document.getElementById('sources');
            var form = document.getElementById('add');
            var field = document.getElementById('source');
            var button = form.querySelector('button');
            var error = document.getElementById('error');

            // Rows are built here (and on the host's callback) from text, never markup —
            // titles come from other people's feeds.
            function addRow(source) {
              var empty = sources.querySelector('.empty');
              if (empty) { empty.remove(); }
              var row = document.createElement('div');
              row.className = 'source';
              row.dataset.url = source.url;
              var text = document.createElement('span');
              text.className = 'source-text';
              var title = document.createElement('span');
              title.className = 'source-title';
              title.textContent = source.title;
              var host = document.createElement('span');
              host.className = 'source-host';
              try { host.textContent = new URL(source.url).host; } catch (err) { host.textContent = source.url; }
              text.appendChild(title);
              text.appendChild(host);
              row.appendChild(text);
              if (source.language) {
                var lang = document.createElement('span');
                lang.className = 'source-lang';
                lang.textContent = source.language;
                row.appendChild(lang);
              }
              var remove = document.createElement('button');
              remove.className = 'source-remove';
              remove.type = 'button';
              remove.setAttribute('aria-label', 'Remove ' + source.title);
              remove.innerHTML = '\(removeIcon)';
              row.appendChild(remove);
              sources.appendChild(row);
            }

            function idle() {
              button.disabled = false;
              button.textContent = 'Add';
            }

            form.addEventListener('submit', function (e) {
              e.preventDefault();
              var value = field.value.trim();
              if (!value || button.disabled) { field.focus(); return; }
              error.hidden = true;
              button.disabled = true;
              button.textContent = 'Adding…';
              post('readerAddSource', value);
            });
            field.addEventListener('input', function () { error.hidden = true; });

            sources.addEventListener('click', function (e) {
              var button = e.target.closest('.source-remove');
              if (!button) { return; }
              var row = button.closest('.source');
              post('readerRemoveSource', row.dataset.url);
              row.remove();
              if (!sources.querySelector('.source')) {
                var empty = document.createElement('p');
                empty.className = 'empty';
                empty.textContent = 'No sources. Suggestions stay empty until you add one.';
                sources.appendChild(empty);
              }
            });

            var blocked = document.getElementById('blocked');
            if (blocked) {
              blocked.addEventListener('click', function (e) {
                var button = e.target.closest('.source-remove');
                if (!button) { return; }
                var row = button.closest('.source');
                post('readerUnblockHost', row.dataset.host);
                row.remove();
                // Last one gone: drop the whole section, heading and hint included, rather
                // than leaving a titled empty box behind.
                if (!blocked.querySelector('.source')) {
                  document.getElementById('blockedSection').remove();
                }
              });
            }

            var langs = document.querySelector('.langs');
            if (langs) {
              langs.addEventListener('change', function () {
                var checked = Array.prototype.filter.call(
                  langs.querySelectorAll('input'), function (input) { return input.checked; });
                post('readerSetLanguages', checked.map(function (input) { return input.value; }));
              });
            }

            document.getElementById('done').addEventListener('click', function () {
              post('readerHome', '');
            });

            // Called by the host once it has fetched (or failed to fetch) the address.
            window.readerSourceAdded = function (source) {
              idle();
              field.value = '';
              addRow(source);
            };
            window.readerSourceRejected = function (message) {
              idle();
              error.textContent = message || 'No feed found at that address.';
              error.hidden = false;
              field.focus();
              field.select();
            };
          })();
          </script>
        </body>
        </html>
        """
    }

    /// A source row. Built in Swift for the same reason recents rows are: the title comes
    /// from someone else's feed and goes through `HTML.escape` here.
    private static func row(_ source: FeedSource) -> String {
        let language = source.language.map {
            "<span class=\"source-lang\">\(HTML.escape($0))</span>"
        } ?? ""
        return """
        <div class="source" data-url="\(HTML.escape(source.url))">
          <span class="source-text">
            <span class="source-title">\(HTML.escape(source.title))</span>
            <span class="source-host">\(HTML.escape(source.host))</span>
          </span>
          \(language)
          <button class="source-remove" type="button" aria-label="Remove \(HTML.escape(source.title))">
            \(removeIcon)
          </button>
        </div>
        """
    }

    /// A blocked outlet's row. Host text comes from a feed, so it is escaped like everything
    /// else here.
    private static func blockedRow(_ host: String) -> String {
        """
        <div class="source" data-host="\(HTML.escape(host))">
          <span class="source-text">
            <span class="source-title">\(HTML.escape(host))</span>
          </span>
          <button class="source-remove" type="button" aria-label="Unblock \(HTML.escape(host))">
            \(removeIcon)
          </button>
        </div>
        """
    }

    /// The same 15px line-icon X as the hidden-phrases popover uses.
    private static let removeIcon = """
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" \
    stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>
    """

    /// A readable name for a language code, falling back to the code itself. Only the
    /// languages a source can actually declare need a name; the rest read as "da", which is
    /// still better than nothing.
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}
