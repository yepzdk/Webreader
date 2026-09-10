import Foundation

/// The settings page: suggestion sources, and where sync stands. Pure like the other
/// generated pages, sharing `ReaderChrome`'s palette and the start page's document shape.
///
/// Appearance is NOT here — it belongs in the Aa popover, next to the text it changes. What
/// lives here is what has nowhere else to go: a list of feeds, which is data the user
/// manages rather than a control they nudge while reading, and the way into sync (this is
/// where people look for it; the sheet itself is native, since it owns a folder picker).
///
/// Getting back out is the top-left nav slot every other page uses (`ReaderChrome.navHome`),
/// not a button at the end of the document. There used to be a "Done" below the shortcut
/// table; it committed nothing — every change here posts the moment it is made — and on a page
/// with a few sources it sat below the fold, so the only way home was off screen (#15).
///
/// The keyboard shortcut reference at the bottom is here for the same reason, from the
/// other direction: the GTK host has no menu bar, so there is nowhere else to read the
/// chords off. It is static text, and `platform` picks which column of them to print.
public enum SettingsPage {
    /// `platform` selects the font stacks and the keyboard chords the shortcut section
    /// lists, defaulting to macOS so the AppKit host needs no argument; a GTK host passes
    /// `.linux`. `palette` is the desktop palette for `Theme.auto`, nil by default so the
    /// `prefers-color-scheme` fallback stands.
    ///
    /// The Sync section is drawn only when the host passes a `syncSummary`: it opens a
    /// native sheet with a folder picker, and a host without one (the GTK host, for now)
    /// would be showing a button that does nothing. `syncFolder` is the abbreviated path of
    /// the folder sync runs through, nil when sync is off. Both strings come from the host
    /// so the page and its sheet can't describe sync differently.
    public static func html(appName: String,
                            settings: ReaderSettings = ReaderSettings(),
                            suggestions: SuggestionSettings = SuggestionSettings(),
                            hidden: HiddenPhrases = HiddenPhrases(),
                            platform: Platform = .macOS,
                            palette: ReaderPalette? = nil,
                            syncFolder: String? = nil,
                            syncSummary: String = "") -> String {
        let name = HTML.escape(appName)
        let sans = platform.sansStack
        // The shared touch floor, bound once so the rules below read as CSS.
        let touchTarget = ReaderChrome.touchTarget
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
                    return "<label class=\"check\"><input type=\"checkbox\" value=\"\(HTML.escape(code))\""
                        + (checked ? " checked" : "") + "><span>\(HTML.escape(languageName(code)))</span></label>"
                }.joined(separator: "\n            "))
              </div>
        """
        // Thumbnails, one switch per surface. They used to be one switch in the Aa popover
        // labelled "Images / No images", which read as governing the article's own images —
        // it never did, it only ever governed the thumbnails in these lists. Split and moved
        // here, where a setting is expected and can afford to say what it does.
        let startChecked = settings.startPageThumbnails == .on ? " checked" : ""
        let readerChecked = settings.readerThumbnails == .on ? " checked" : ""
        let imagesSection = """
        <h2 class="section">Article images</h2>
              <p class="help" id="imagesHelp">The article's own lead image, shown beside its
              row. A list with this off carries no images, reserves no space for them, and
              fetches nothing.</p>
              <div class="checks" role="group" aria-label="Article images"
                   aria-describedby="imagesHelp">
                <label class="check">
                  <input id="\(ReaderSettings.ThumbnailScope.startPage.rawValue)" type="checkbox"\(startChecked)>
                  <span>Show thumbnail image next to recents and suggested on the start page</span>
                </label>
                <label class="check">
                  <input id="\(ReaderSettings.ThumbnailScope.reader.rawValue)" type="checkbox"\(readerChecked)>
                  <span>Show thumbnail image next to recents and suggested in the reader dropdown</span>
                </label>
              </div>
        """
        // Which of the start page's two lists leads. A checkbox, not a pair of segmented
        // buttons like the Aa popover's: the choice is two-way and every switch on this page
        // is a checkbox. What it writes is still an enum (`StartPageOrder`), so the stored
        // value says which order it means rather than which box happened to be ticked.
        let suggestionsFirst = settings.startPageOrder == .suggestionsFirst ? " checked" : ""
        let controlsLeft = settings.controlSide == .left ? " checked" : ""
        let sideSection = """
        <h2 class="section">Reader controls</h2>
              <p class="help" id="sideHelp">On a touch screen the reader\'s buttons collapse
              into one column against an edge, in reach of the hand holding the device. Pick
              the edge.</p>
              <label class="check">
                <input id="controlSide" type="checkbox" aria-describedby="sideHelp"\(controlsLeft)>
                <span>Put the reader\'s controls on the left</span>
              </label>
        """
        let orderSection = """
        <h2 class="section">Start page</h2>
              <p class="help" id="orderHelp">Recent articles lead the page. Turn this on to
              land on the suggestions instead, without scrolling past your own history.</p>
              <label class="check">
                <input id="startPageOrder" type="checkbox" aria-describedby="orderHelp"\(suggestionsFirst)>
                <span>Show suggested articles before recent articles</span>
              </label>
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
        // Only for a host that has somewhere to send the button: it opens a native sheet
        // with a folder picker, and drawing it on a host without one (the GTK host, until
        // #7's Linux half lands) would be a control that does nothing.
        let syncSection = syncSummary.isEmpty ? "" : """
        <h2 class="section">Sync</h2>
              <p class="help">Appearance and recents follow you between your devices through a
              folder that already syncs — in your Nextcloud folder, iCloud Drive, or anything
              similar. Page zoom stays on this device.</p>
              <div class="sync">
                <span class="sync-text">
                  <span class="sync-folder">\(HTML.escape(syncFolder ?? "Not set up"))</span>
                  <span class="sync-state">\(HTML.escape(syncSummary))</span>
                </span>
                <button id="syncOpen">\(syncFolder == nil ? "Set up…" : "Change…")</button>
              </div>
        """
        // Hidden text, managed the same way blocked outlets are: created while reading (a
        // selection in the reader), listed and removed here (#32). The reader's popover
        // stays, because grouping phrases by whether they hit the article on screen is
        // something only that page can do.
        //
        // Unlike the blocklist this section always renders, empty or not. `HiddenPhrases`
        // never re-seeds a list that has been emptied, so removing the last phrase is
        // permanent — and with #readerHiddenBtn gone from the start page, the section's help
        // line is the only written trace the feature has. Deleting the section with its last
        // row would delete the instructions for getting a row back.
        let phraseRows = hidden.phrases.isEmpty
            ? "<p class=\"empty\">No hidden text.</p>"
            : hidden.phrases.map(phraseRow).joined(separator: "\n              ")
        let hiddenSection = """
        <section id="hiddenSection">
                <h2 class="section">Hidden text</h2>
                <p class="help">Removed from every article. Hide a phrase by selecting it in
                the reader.</p>
                <div id="hiddenPhrases">
                  \(phraseRows)
                </div>
              </section>
        """
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings))>
        <head>
        <meta charset="utf-8">
        \(ReaderChrome.viewportMeta)
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="WebReader Settings">
        <title>Settings — \(name)</title>
        \(ReaderChrome.transportScript(platform: platform))
        <style>
          \(ReaderChrome.indent(ReaderChrome.themeCSS(settings, platform: platform,
                                                      palette: palette), by: 10))
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 10))
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
            /* Mobile first. The base top padding clears the fixed nav button for the one
               case that still has it at the top: a pointer in a window narrower than the
               breakpoint. */
            padding-top: 56px;
            padding-bottom: 48px;
            padding-left: max(16px, var(--safe-left));
            padding-right: max(16px, var(--safe-right));
          }
          @media (min-width: 34rem) and (pointer: fine) {
            main {
              padding-top: 10vh; padding-bottom: 64px;
              padding-left: max(24px, var(--safe-left));
              padding-right: max(24px, var(--safe-right));
            }
          }
          /* Last, so it wins at every width. On a compact viewport the chrome is a floating
             button in the bottom-right corner, so the headroom goes back to what the content
             wants — plus whatever a notch or a Dynamic Island takes, since the page is drawn
             edge to edge — and the foot clears the button, which ends 58px up. Keyed on the
             same condition the chrome is, because it is the same fact about the layout. */
          @media \(ReaderChrome.compactViewport) {
            main {
              padding-top: \(ReaderChrome.inset(32, "top"));
              padding-bottom: \(ReaderChrome.inset(78, "bottom"));
            }
          }
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
          /* Checkbox rows: the language filter's boxes and the article-image switches. One
             definition — they are the same control in the same page's voice. `.langs` wraps
             its boxes into a row; `.checks` stacks a switch per line.
             Top-aligned, not centred: a label long enough to wrap would otherwise leave its
             box floating in the middle of two lines. The nudge lines it up with the first
             line's text rather than the line box. */
          .checks { display: flex; flex-direction: column; gap: 10px; }
          .check { display: flex; align-items: start; gap: 8px; font-size: 13px; cursor: pointer; }
          .check input { margin-top: 2px; accent-color: var(--accent); }
          /* Sync: where it runs and how it's doing, with the control that opens the sheet. */
          .sync {
            display: flex; align-items: center; gap: 12px;
            padding: 10px 2px; border-bottom: 1px solid var(--border);
          }
          .sync-text { flex: 1; min-width: 0; }
          .sync-folder {
            display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            font-size: 14px;
          }
          .sync-state { display: block; margin-top: 1px; font-size: 12px; color: var(--muted); }
          #syncOpen {
            flex: none; padding: 7px 12px;
            font-family: inherit; font-size: 13px; color: var(--fg);
            background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
            cursor: pointer;
          }
          #syncOpen:hover { background: var(--surface); }
          /* The shortcut reference: a list you read, so plain markup — nothing in it is a
             control, which is why the section needs no script and no host of its own. The
             columns carry no gap so the hairline is one rule across the row, as the source
             rows above are; the chord column keeps its distance with padding instead. */
          .keys { display: grid; grid-template-columns: 1fr auto; margin: 0; }
          .keys dt, .keys dd {
            margin: 0; padding: 10px 2px; font-size: 14px;
            border-bottom: 1px solid var(--border);
          }
          .keys dd { padding-left: 16px; text-align: right; }
          .key-note { display: block; margin-top: 3px; font-size: 11px; color: var(--muted); }
          kbd {
            font-family: ui-monospace, SFMono-Regular, Menlo, "DejaVu Sans Mono", monospace;
            font-size: 12px; padding: 1px 6px; white-space: nowrap;
            background: var(--surface); border: 1px solid var(--border); border-radius: 4px;
          }
          /* Touch: every control reaches the 44px floor, and the field's text goes to 16px
             so mobile Safari does not zoom the page in on focus. The checkbox itself stays
             small — the whole `.check` label is the target, which is why it takes the floor
             and the box only needs `flex: none` to stop the row squashing it to 13px. The
             label keeps the base `align-items: start`: the article-image label wraps at
             phone widths, and centring a wrapped label leaves its box floating between the
             lines — the case that rule was written for. */
          @media (pointer: coarse) {
            .source-remove {
              min-height: \(touchTarget)px; min-width: \(touchTarget)px;
              align-items: center; justify-content: center;
            }
            #source { padding: 12px; font-size: 16px; min-height: \(touchTarget)px; }
            form button { padding: 12px 18px; font-size: 16px; min-height: \(touchTarget)px; }
            .check { min-height: \(touchTarget)px; }
            .check input { flex: none; width: 20px; height: 20px; margin-top: 0; }
            .langs { gap: 0 18px; }
            #syncOpen { min-height: \(touchTarget)px; padding: 10px 14px; font-size: 15px; }
          }
          \(ReaderChrome.indent(ReaderChrome.backdropCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.chromeCSS(platform: platform), by: 10))
        </style>
        </head>
        <body>
          \(ReaderChrome.backdrop())
          \(ReaderChrome.indent(ReaderChrome.chrome(nav: ReaderChrome.navHome()), by: 2))
          <main>
            <h1>Settings</h1>
            <p class="lede">\(syncSection.isEmpty ? "Sources feed the suggestions on the start page."
                : "What the start page suggests, and how this device stays in step with your others.")</p>

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

            \(syncSection)

            \(hiddenSection)

            \(imagesSection)

            \(orderSection)

            \(sideSection)

            \(ReaderChrome.indent(shortcutSection(platform: platform), by: 4))
          </main>
          <script>
          (function () {
            // `readerPost` is defined in <head>; this alias keeps the call sites below on
            // the short name they have always used.
            var post = window.readerPost;
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

            var phrases = document.getElementById('hiddenPhrases');
            if (phrases) {
              phrases.addEventListener('click', function (e) {
                var button = e.target.closest('.source-remove');
                if (!button) { return; }
                var row = button.closest('.source');
                post('readerUnhide', row.dataset.phrase);
                row.remove();
                // Unlike the blocklist, the last row does NOT take the section with it: the
                // help line above is the only place the app says how to hide a phrase, and
                // an emptied list is never re-seeded, so removing it would remove the
                // instructions for getting a row back. Same empty state the sources list uses.
                if (!phrases.querySelector('.source')) {
                  var empty = document.createElement('p');
                  empty.className = 'empty';
                  empty.textContent = 'No hidden text.';
                  phrases.appendChild(empty);
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

            // The two thumbnail switches; each box's id is the settings key it writes.
            //
            // Only the changed key is posted. This page's copy of the settings would be as
            // old as the document — a back/forward restore reuses the original bytes — so
            // posting a whole object from here would push a stale font size and theme over
            // newer ones. The host merges a payload onto the settings as stored
            // (`ReaderSettings.decode(_:onto:)`), which is what makes one key safe to send.
            ['\(ReaderSettings.ThumbnailScope.startPage.rawValue)',
             '\(ReaderSettings.ThumbnailScope.reader.rawValue)'].forEach(function (key) {
              var box = document.getElementById(key);
              if (!box) { return; }
              box.addEventListener('change', function () {
                var change = {};
                change[key] = box.checked ? 'on' : 'off';
                post('readerSettings', change);
              });
            });

            // The start page's section order, posted a key at a time for the same reason the
            // switches above are. Ticked means suggestions first; the value spells the order
            // out rather than sending a boolean, because that is what is stored.
            var order = document.getElementById('startPageOrder');
            if (order) {
              order.addEventListener('change', function () {
                post('readerSettings', {
                  startPageOrder: order.checked ? 'suggestionsFirst' : 'recentsFirst'
                });
              });
            }

            // Which edge the reader's chrome sits against. Ticked means left; the value
            // names the side rather than sending a boolean, for the same reason the order
            // switch above spells its order out.
            var side = document.getElementById('controlSide');
            if (side) {
              side.addEventListener('change', function () {
                post('readerSettings', { controlSide: side.checked ? 'left' : 'right' });
              });
            }

            // Absent on a host that has no sync sheet to open (see `syncSection`), so both
            // halves check before touching it.
            var syncOpen = document.getElementById('syncOpen');
            if (syncOpen) {
              syncOpen.addEventListener('click', function () {
                post('readerOpenSync', '');
              });
              // The host pushes the two sync strings after the sheet changes anything, rather
              // than re-rendering the page: a half-typed feed address in the field above must
              // survive someone setting up sync.
              window.readerSetSyncStatus = function (folder, summary) {
                document.querySelector('.sync-folder').textContent = folder || 'Not set up';
                document.querySelector('.sync-state').textContent = summary || '';
                syncOpen.textContent = folder ? 'Change…' : 'Set up…';
              };
            }

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

    /// A hidden phrase's row. The phrase came from a page the user was reading, so it is
    /// escaped here — in the title and in the attribute the remove control posts back.
    private static func phraseRow(_ phrase: String) -> String {
        """
        <div class="source" data-phrase="\(HTML.escape(phrase))">
          <span class="source-text">
            <span class="source-title">\(HTML.escape(phrase))</span>
          </span>
          <button class="source-remove" type="button" aria-label="Stop hiding \(HTML.escape(phrase))">
            \(removeIcon)
          </button>
        </div>
        """
    }

    /// A host command and the chords that invoke it, both platforms in the same row.
    ///
    /// The two sets genuinely differ — Linux stays on Ctrl so it never reaches for a key
    /// Hyprland has already taken on Super — and two hand-written lists would be two
    /// things to forget, so the page picks a column out of one table exactly as the font
    /// stacks pick a stack out of `Platform`.
    ///
    /// Chords are held one per element rather than as a single "A / B / C" string so each
    /// renders as its own `<kbd>` and the separator stays a rendering decision.
    struct Shortcut {
        let action: String
        let macOS: [String]
        let linux: [String]
        /// Set where the chord belongs to the web view rather than to us, so the row can
        /// say so instead of implying a binding the host never registers.
        var linuxNote: String? = nil

        func chords(for platform: Platform) -> [String] {
            switch platform {
            case .macOS: return macOS
            case .linux: return linux
            // No chords are bound on a touch host, and `shortcutSection` renders nothing
            // there, so this is unreachable in practice. Empty rather than a trap: the
            // honest answer to "which chords invoke this" is "none".
            case .iOS, .android: return []
            }
        }

        func note(for platform: Platform) -> String? {
            switch platform {
            case .macOS, .iOS, .android: return nil
            case .linux: return linuxNote
            }
        }
    }

    /// Every host command, in the order the macOS menu bar lists them. The Linux column is
    /// the accelerator table in `WebReaderGTK.Application.Command`; keep the two together.
    static let shortcuts: [Shortcut] = [
        Shortcut(action: "Open URL from clipboard", macOS: ["⇧⌘O"], linux: ["Ctrl+Shift+O"]),
        Shortcut(action: "Toggle reader view", macOS: ["⇧⌘R"], linux: ["Ctrl+Shift+R"]),
        Shortcut(action: "Home (start page)", macOS: ["⇧⌘H"], linux: ["Ctrl+Shift+H"]),
        Shortcut(action: "Copy current URL", macOS: ["⇧⌘C"], linux: ["Ctrl+Shift+C"]),
        Shortcut(action: "Settings", macOS: ["⌘,"], linux: ["Ctrl+,"]),
        Shortcut(action: "Reload", macOS: ["⌘R"], linux: ["Ctrl+R"]),
        Shortcut(action: "Zoom in / out / reset",
                 macOS: ["⌘+", "⌘−", "⌘0"], linux: ["Ctrl++", "Ctrl+−", "Ctrl+0"]),
        // Not a host action on Linux at all: the web view already does this, and listing
        // the chords without saying whose they are would read as an app binding.
        Shortcut(action: "Back / forward", macOS: ["⌘[", "⌘]"], linux: ["Alt+←", "Alt+→"],
                 linuxNote: "Handled by WebKitGTK, not bound by the app."),
    ]

    /// The shortcut reference, in the chords of the platform the page is being rendered
    /// for. Static markup on purpose: this is a list you consult, not a control you use,
    /// so it costs neither a script message handler nor a line of host code on either side.
    ///
    /// It comes after the sources, languages and blocked outlets because those are what
    /// someone opened Settings to change; a reference belongs below the things you act on.
    static func shortcutSection(platform: Platform) -> String {
        // A host that binds no chords has no reference to print. Returning "" rather than
        // an empty table for the same reason the Sync section is gated on `syncSummary`:
        // a heading over nothing is a promise the page cannot keep.
        guard platform.hasKeyboardCommands else { return "" }
        // The one sentence the section owes the reader, and on Linux it is the whole
        // reason the section exists: the GTK host has no menu bar to read the chords off.
        let help = platform == .linux
            ? "The Linux app has no menu bar, so its keyboard shortcuts are listed here."
            : "The same commands are in the menu bar; this is the whole list."
        // Ours, not anyone's feed — but escaped along the same route as everything else on
        // the page, so no reader has to work out why this one string is the exception.
        let rows = shortcuts.map { shortcut -> String in
            let keys = shortcut.chords(for: platform)
                .map { "<kbd>\(HTML.escape($0))</kbd>" }
                .joined(separator: " / ")
            let note = shortcut.note(for: platform)
                .map { "<span class=\"key-note\">\(HTML.escape($0))</span>" } ?? ""
            return "<dt>\(HTML.escape(shortcut.action))</dt>\n<dd>\(keys)\(note)</dd>"
        }
        return """
        <h2 class="section">Keyboard shortcuts</h2>
        <p class="help">\(HTML.escape(help))</p>
        <dl class="keys">
          \(ReaderChrome.indent(rows.joined(separator: "\n"), by: 2))
        </dl>
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
