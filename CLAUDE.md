# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

WebReader is a macOS reading app: it receives links (browser picker, `open -a`, ⇧⌘O, start
page) and renders articles as a clean reader page via Mozilla Readability. It was split out
of [yepzdk/webwrap](https://github.com/yepzdk/webwrap) in August 2026; webwrap's reader is
frozen at 0.8.0 and all reader work happens here.

Roadmap (not started): read-aloud (`AVSpeechSynthesizer` over Readability's `textContent`),
a feed of similar articles, and an iOS/iPadOS app (#6) — which reuses the folder sync that
already ships (`Sources/ReaderKit/Sync`), with iCloud Drive as the practical folder there.

## Architecture

Three SwiftPM targets on a Mac, three on Linux, three for Android behind an environment
switch, two more built only by Xcode, no dependencies:

- **`Sources/ReaderKit`** — Foundation-only. Must stay free of AppKit/WebKit/UIKit so every
  host depends on it unchanged — including the Android one, which compiles it for
  `aarch64-unknown-linux-android28`. Everything here is pure string/JSON work and
  unit-tested:
  - `ReaderSession.swift` + `+Messages.swift` + `+Sync.swift` — **the reader itself**: which
    of our pages is on screen, when a page is offered to Readability, what each of the
    seventeen script messages means, and what to draw next. It touches no web view: every
    answer is a `[ReaderCommand]` the host runs (`.load`, `.show`, `.evaluate`, `.extract`,
    `.reject`, `.openExternally`, `.presentSyncSetup`, `.fetchSuggestions`, `.resolveSource`).
    All three hosts drive this one implementation — which is the point, since the fourth
    cannot even be written in Swift.
  - `Reader.swift` — `Article`, `ReaderSettings` (appearance, tolerant JSON codec),
    `Reader.extractionScript` (Readability over a cloned document), `ReaderPage.html`.
  - `ReaderChrome.swift` — the Aa popover, recents popover, theme palette, and scroll-progress
    line shared byte-for-byte by the reader page and the start page.
  - `ReaderHistory.swift` — recents (cap 30, dedupe by URL).
  - `ArticleCache.swift` — one JSON file per recent article in the host-supplied Caches
    directory, keyed by FNV-1a of the cleaned URL (verified on read).
  - `Suggestions.swift` — `FeedSource`/`SuggestionSettings` (the user's sources, seeded with
    wallnot.dk), `Feed.parse` (RSS 2.0 + Atom via `XMLParser`) / `Feed.discover`, and
    `Suggestions.rank`.
  - `FeedFetcher.swift` — the only networking outside the web view: an actor fetching the
    sources with a 10-minute in-memory TTL; failures are "no items", never errors.
  - `SettingsPage.swift` — the suggestion sources, the language filter, and the way into
    sync (⌘,).
  - `HiddenPhrases.swift` — boilerplate phrases removed from articles (cap 100) and the JS
    `readerHideBlocks` that does it, shared by the extraction script and the live reader page.
  - `StartPage.swift`, `OfflinePage.swift` (`OfflineFallback` + `HTML.escape`).
  - `URLCleaner.swift` — tracking-redirect unwrap / tracking-param strip (ported from
    yepzdk/url-cleaner; never unwraps OAuth `redirect*` params or unencoded nested URLs).
  - `WebURL.swift` — `isWebURL`, `loadsInApp`, `clipboardURL`, `urlToCopy`.
  - `ReaderStore.swift` — `KeyValueStore` protocol, `DefaultsStore`, and the keys/bounds for
    settings, history, and zoom. Strings only, so a KVS-backed store can drop in for sync.
  - `Sync/` — sync (#7) as files in a folder the user picks, one per device:
    `DeviceState.swift` (the file format), `SyncMerge.swift` (fold across devices),
    `SyncFolder.swift` (the folder's I/O, injected like `ArticleCache`), `SyncEngine.swift`
    (one cycle: read peers, fold, write back, publish).
  - `ReadabilityJS.swift` — vendored Readability 0.6.0 as string literals (Apache-2.0). To
    upgrade, replace both literals and bump `version`.
  - `Platform.swift` — `Platform.macOS` / `.linux` and the serif/sans CSS font stacks each
    one ships. A value, never `#if os(...)`: the page generators take `platform:` (defaulting
    to `.macOS`, which is what keeps the AppKit host's call sites argument-free), so the
    choice isn't tied to the compiling OS and the tests assert both.
  - `ReaderPalette.swift` — the six colour roles (`--bg`, `--fg`, `--muted`, `--accent`,
    `--border`, `--surface`) plus `isDark`, injected as `palette:` beside `platform:`.
    Honoured **only** under `Theme.auto`; an explicit theme still pins its own palette.
  - `FileStore.swift` — `KeyValueStore` over one atomically-written JSON file. `DefaultsStore`
    is right on macOS, but corelibs-Foundation's `UserDefaults` location is not a stable
    contract, so the Linux host uses this instead. Missing or corrupt file reads as empty.
- **`Sources/ReaderWebKit`** — the WKWebView half of a host: `ReaderWebController` owns the
  web view, the page-state machine, the extraction flow, the seventeen script-message
  handlers and the `window.reader*` pushes. Foundation + WebKit only, so the AppKit shell and
  the iOS one (#6) run the same code rather than two copies of it — the GTK host necessarily
  reimplements it and has already drifted (`isShowingFallback`). What has no cross-platform
  spelling reaches the shell through `ReaderHostServices` (reject, open externally, bring to
  front, present sync setup), `ReaderLoadingCover` and `ReaderSyncBridge`.
  `ReaderSyncController.swift` runs the sync cycles for both Apple hosts; the four things
  that differ — device name, the "sync is off" sentence, how a folder is remembered, and
  whether it has to be claimed — are a `ReaderSyncPlatform` the shell supplies. Its tests
  drive a real `WKWebView` off screen and click the real generated pages.
- **`Sources/WebReader`** — the AppKit shell. `AppDelegate.swift` owns the window, the menu,
  URL handling (`application(_:open:)` + the GetURL Apple Event), page zoom, the clipboard,
  and answers `ReaderHostServices` with `NSSound.beep()`/`NSWorkspace`. `ProgressLine.swift`
  is the native load-progress hairline and `LoadingCover.swift` the plain "Loading" screen
  that stands in for a site while it loads. `LegacyImport.swift` is the one-time import from
  the webwrap-generated app's defaults domain (`dk.yepz.webwrap.webreader`).
  `MacSyncPlatform.swift` is the Mac's answer to `ReaderSyncPlatform` (unsandboxed: nothing
  to claim, plain bookmarks) and `SyncSheet.swift` is the Sync… sheet — the only native
  window in the app.
- **`Sources/WebReaderiOS`** — the UIKit shell (#6), built by `WebReader.xcodeproj` rather
  than SwiftPM, since only Xcode produces an `.app` for iOS. `ReaderViewController` is the
  whole app: it owns the store, the cache and sync, answers `ReaderHostServices` with a
  haptic and `UIApplication.open`, and pins the web view to the screen edges with
  `contentInsetAdjustmentBehavior = .never` — the pages are drawn edge to edge and place
  themselves with `env(safe-area-inset-*)`, so letting UIKit inset as well counts the notch
  twice. `SceneDelegate` routes the three ways a link arrives (cold launch, `openURLContexts`,
  and the share extension's hand-off on activation). `IOSSyncPlatform` is the sandboxed
  `ReaderSyncPlatform`: a document-picker folder is claimed with
  `startAccessingSecurityScopedResource` for as long as sync uses it, and its bookmark is
  made while that claim is held. There is no page zoom — `WKWebView` has none on iOS.
- **`Sources/WebReaderShare`** — the "Read in WebReader" share extension. No interface: it
  normalises the shared link with `WebURL.clipboardURL`, leaves it in the App Group store
  under `reader.pendingOpen`, and asks the system to open `webreader://open`. The store is
  what carries the link — `NSExtensionContext.open` may be declined, and then the app picks
  the link up the next time it comes forward instead of losing it.
- **`Sources/CWebKitGTK`** — a header-only C shim, `shim.h` plus a module map. It exists
  because Swift's ClangImporter cannot see function-like C macros (`g_signal_connect`,
  `G_CALLBACK`, the `GTK_WIDGET()`/`WEBKIT_WEB_VIEW()` casts) or C varargs (`g_object_new`).
  Every signal gets a typed `wr_connect_*` so the C compiler checks the callback signature
  instead of Swift `unsafeBitCast`ing a function pointer. Flag enumerators need a wrapper too:
  `GApplicationFlags` imports as a `RawRepresentable` struct, so `G_APPLICATION_HANDLES_OPEN`
  is not in Swift scope — hence `wr_application_handles_open()`.
- **`Sources/WebReaderGTK`** — the GTK4 + WebKitGTK 6.0 host (`webreader`), issue #16.
  `Application.swift` owns the `GtkApplication` (`HANDLES_OPEN`, so a `.desktop` `%u` and
  `xdg-open` arrive on the `open` signal), the window/overlay, the nine `GSimpleAction`
  accelerators and zoom. `ReaderHost.swift` is the reader state machine and the script-message
  handlers. `ProgressStrip.swift` is the load hairline and `LoadingCover.swift` the loading
  screen (an overlay child, added before the strip so the strip stays on top).
  `OmarchyTheme.swift` and `XDG.swift`
  are the platform services. There is **no menu bar**: the WM owns quit and the window verbs,
  WebKitGTK owns the edit verbs, and the web shell already carries the rest.
- **`Sources/ReaderKitAndroid`** — the reader as two C functions, `readerkit_call(name, json)`
  and `readerkit_free`, built into `libReaderKitAndroid.so` by the Swift SDK for Android. One
  dispatcher rather than a function per operation: JNI is at its least troublesome when it
  carries only strings, and adding a call touches the switch and the Kotlin side that names
  it, never the C shim or the build. The session it holds owns its own persistence
  (`FileStore` + `ArticleCache` in the app's own directories, like the Linux host), so Kotlin
  has no preference keys and no state schema.
- **`Sources/CReaderKitJNI`** — the `Java_dk_yepz_webreader_ReaderBridge_call` entry point in
  C, because the symbol name and the `JNIEnv` calling convention are `jni.h`'s to define. It
  transcodes UTF-16 to UTF-8 by hand rather than using `GetStringUTFChars`: JNI's "UTF-8" is
  Modified UTF-8, which would turn any astral character in an article into `U+FFFD`.
- **`android/`** — the Kotlin host (issue #9). One Activity over a `WebView`, the `readerHost`
  JavaScript interface, `ACTION_VIEW` + `ACTION_SEND` intent filters, and the Storage Access
  Framework for sync's folder. `Scripts/build-android.sh` must run first: it fills
  `app/src/main/jniLibs/` with the `.so` and the Swift runtime, ~100 MB per ABI of build
  output that is gitignored. See `android/README.md`.

### Rules that aren't obvious from the code

- The reader renders as its **own document** (`loadHTMLString(_:baseURL:)` with the article
  URL as base), never an in-place DOM swap — hydrating sites revert swaps within a second.
- Page state (`isShowingStartPage`, `isShowingFallback`, `isShowingReader`,
  `pendingReaderRender`) is tracked with explicit flags, not inferred from `webView.url`. The
  flags also gate every script message handler so a live site can't post to them.
- Generated pages talk to the host via `readerRetry`, `readerSettings`, `readerOpen`,
  `readerClear`, `readerOpenURL`, `readerHide`, `readerUnhide`, `readerOpenSettings`,
  `readerHome`, `readerAddSource`, `readerRemoveSource`, `readerSetLanguages`,
  `readerBlockHost`, `readerUnblockHost`, `readerTopicFeedback`, `readerRate`,
  `readerOpenSync`. Rename in both Swift and the page scripts together. The host calls back
  via `window.readerSetHidden(list)`, `window.readerSetSuggestions(items)`,
  `window.readerSourceAdded/Rejected(…)`, `window.readerApplySettings(settings)`,
  `window.readerSetRecents(rows)`, `window.readerSetSyncStatus(folder, summary)`.
- Hiding a phrase is a **page** affordance, not a menu item: selecting text in the reader
  raises a Hide button that posts to `readerHide`. It was moved out of the Edit and context
  menus for issue #16 — the Linux host has no menu bar — and `window.webkit.messageHandlers`
  is the same API on WebKitGTK 6.0, so the page half ports unchanged. Don't reintroduce a
  menu route; there would be two ways to do one thing.
- Hidden phrases match a **whole block's text only** (never a substring, never inline
  elements) so a learned phrase can't rewrite prose. The stored list is seeded with
  `HiddenPhrases.defaults` the first time it's read and is plain user data afterwards — new
  defaults don't reach existing users, and Reset Reader Appearance leaves the list alone.
- Quotation styling is two-step: the extraction script wraps »…«/“…” pairs found in a single
  text node in `<span class="q">` (paragraphs opening with one get `qp`), and the reader
  page's CSS renders them bordered by default or italic under `data-quotes="italic"`.
  Switching the setting is attribute-only — no re-extraction.
- Recents store the **cleaned** URL, because reopening a row routes through `openIncoming`,
  which cleans; the raw URL would look like a different article.
- The article cache mirrors recents exactly (`prune(keeping:)` after every history write and
  on Clear history). Only recents rows and failed loads are served from it — incoming links
  always load live. The cached body is post-filter; phrases learned later still apply
  because the reader page re-runs the hide on load, but a phrase *removed* later only
  reappears after ⌘R (re-extract). Cached renders go through `renderReader` too — it resets
  page state and records history for every entry point — but only a live extraction writes
  the cache.
- Every reader page carries `<meta name="generator" content="WebReader">`, and the
  extraction script returns `Reader.ownPageSentinel` when it sees it, so back/forward onto a
  reader entry marks it as the reader instead of extracting (and caching) our own rendering.
- Suggestion sources are user data like history and hidden phrases: seeded with
  `SuggestionSettings.defaults` on first read, plain data afterwards (removing wallnot.dk
  sticks), and Reset Reader Appearance leaves them alone.
- Ranking is TF-IDF cosine, not `NLEmbedding`: Apple ships no Danish sentence-embedding
  model (nor Swedish or Norwegian), so embeddings would rank the primary use case at random.
  The profile is the recents' cached bodies, falling back to the row's title when the body
  has aged out of the Caches folder.
- Anything interpolated into a generated page's `<script>` goes through `HTML.jsLiteral`,
  never a bare `</` replace: feed titles, article titles and learned phrases are other
  people's text, and `JSONSerialization` leaves U+2028/U+2029 raw — they end a JS statement
  even inside a string literal.
- `TopicPreferences.weights` are accumulated **unclamped**, and bounded only at the point of
  use by `influence(of:)`. Clamping on write makes the stored value stop being a faithful sum
  of the clicks, and an undo then can't reverse it — ten likes saturating at +3 undid to −3,
  a maximal dislike of a repeatedly-liked topic. Same reason the decoder doesn't clamp.
- A rating given in the reader is a toggle, so `TopicPreferences` stores `ratings`
  (cleaned URL → more/less) beside the weights: replaying a rating's own terms is the only
  way to undo it exactly, since the weights are clamped and capped (lossy). The reader page
  bakes the current rating into `aria-pressed`, and `pushRating` refreshes it when
  back/forward restores an already-rendered document.
- Suggestion feedback is deliberately quiet: More/Less stores a `TopicPreferences` weight and
  does NOT re-rank the visible list (rows must not move under the cursor); blocking an outlet
  removes the row and re-runs `loadSuggestions` to refill the slot from the fetcher's TTL
  cache. Both confirm with `ReaderChrome`'s shared toast.
- A blocked outlet is stored as `Suggestions.normalizedHost` — the same string
  `FeedItem.host` displays, so what the user sees is what they blocked. Matching is
  whole-host, never a suffix.
- No feed inspected (wallnot, DR, Information, Rust Blog) carries `<category>`, so there are
  no tag badges: any tag would be a machine-derived keyword dressed up as metadata.
- `PageState` (ReaderKit) owns which generated page is on screen, and `AppDelegate` only
  wires WebKit's callbacks to it. It lives there because the transitions are subtle and the
  host target has no tests: 0.10.0 shipped with `didStartProvisionalNavigation` clearing the
  flag that `loadHTMLString` had just set (WebKit fires it for our own loads too), leaving
  the start page on screen with every message handler gated shut. `willShow` marks a load as
  ours; `navigationStarted` only clears when the navigation is someone else's.
- Every generated page carries a `<meta name="generator">` — `WebReader` (reader, matched
  EXACTLY by the extraction script), `WebReader Start`, `WebReader Settings`. They are real
  back/forward entries, so `didStartProvisionalNavigation` clears the page flags and
  `didFinish` re-establishes them by reading the marker; without that, ⌘[ off Settings left
  every start-page handler gated shut.
- The start page renders before suggestions exist: the section ships hidden and empty, the
  host fills it via `window.readerSetSuggestions` when the fetch lands, and the task is
  cancelled on any navigation away. Nothing about suggestions can block or fail the page.
- The chrome is **two fixed corners on one baseline**: `.reader-controls` top-right, and
  `.reader-nav` top-left holding exactly one button (Home on the reader, settings and offline
  pages; Settings on the start page, which *is* home). Both declare `top: 14px` and
  share one `buttonBox` declaration, so a button on one side cannot drift from the other; a
  test pins both. The nav slot is deliberately NOT a second `.reader-controls` —
  `controlsScript` dismisses an open popover on any click outside that class, and reusing it
  would silently break the dismissal. Its button posts inline rather than through
  `controlsScript`, because the offline page carries no chrome script.
- `readerHome` is reachable from any page of ours **and** the offline page (`ownPage ||
  isShowingFallback`), not just Settings. Try Again retries the URL that failed, so without
  Home the offline page was a dead end — and on Linux there is no menu bar to escape through.
- The settings page has **no "Done"**. It had one, after the shortcut table, and with a handful
  of sources it sat below the fold: the only route home was off screen. It also committed
  nothing — every change on that page posts the moment it is made — so the label promised a
  transaction that does not exist. The nav slot is the one way out, as on every other page.
- The loading cover is **native, not a generated page**. A `loadHTMLString` cover would be a
  real back/forward entry between every pair of pages; `PageState.navigationStarted()`
  early-returns while a load of ours is pending, so the real navigation's completion would be
  consumed as "our own page landed" and extraction would never run; and the hairline tracks
  the web view's own `estimatedProgress`, so a cover page's load would drive it to full and
  fade it before the real load started. Stacking between the web view and the hairline avoids
  all three — hence `ProgressLine` adds its bar `relativeTo: nil` (front-most), and the GTK
  cover is added to the overlay *before* `ProgressStrip`.
- The cover comes down at **choke points**, not per-flag: `loadOwnPage` (AppKit) /
  `loadHTML` (GTK) is the single own-document funnel and hides it, setting a one-shot
  `coverSuppressedOnce` that the next navigation-start consumes. A test over the page flags
  instead would have missed the offline page, which sets none of them — that is how a page
  gets stuck behind "Loading". The other reveals are extraction declining, the own-page
  sentinel, an ignorable load failure, and the reader toggle (which wants the site).
- The cover's watchdog measures **silence, not elapsed time**. It shipped as a fixed 10 s cap
  from the moment the cover went up, which on a slow connection fired mid-load and revealed the
  site the cover exists to hide. Each host now watches `estimatedProgress` /
  `estimated-load-progress` itself and re-arms `LoadProgress.coverStallPatience` on every
  change, so a load that is still moving is waited for however long it takes and only a stall
  reveals the page. Measured against a deliberately slow local server: trickling for 24 s keeps
  the cover up, headers-then-nothing drops it at 6.3 s. The cover owns this rather than being
  fed progress by the delegate — whether it may come down is its own business.
- The cover's copy is `LoadProgress.coverMessages`, one picked per appearance. All short and
  all in the same register (what the reader does to a page — stripping it back to type), 138–237 px
  at 20 pt: a sentence risks clipping in a narrow window, and mixing a two-word message with a
  nine-word one makes the cover lurch between loads. Picked per load, never per frame — a label
  changing under you mid-wait reads as a glitch.
- `ReaderPalette.stock(for:prefersDark:)` is the **one** place the theme colours live;
  `ReaderChrome.themeCSS` renders its stylesheet from those values and the native covers read
  the same ones, so a cover cannot be a different colour from the page behind it. Same
  arrangement as `LoadProgress.lineThickness`. A test pins the CSS against the palette.
- Suggestion thumbnails come from the **feed**, not from the article: a suggested piece has
  not been visited, so there is no document to read an `og:image` from, and fetching every
  candidate's page for a thumbnail would be one request per row to publishers the reader
  never opened. `media:thumbnail` / `media:content` / an image `enclosure` first, then the
  first `<img>` in the item's summary — Information, The Verge and The New Stack carry no
  structured tag at all, while The Guardian and Ars Technica carry nothing else. Coverage is
  genuinely uneven and **wallnot.dk, the shipped default, publishes no images whatsoever**,
  so imageless rows are the normal case, not an edge case.
- `Feed.bestImage` picks the **smallest** declared width at or above 128px (a 64px row at 2x),
  not the first or the largest: The Guardian ships 140/460/700 per item and Ars a 1152px hero,
  so first-wins is either soft or several hundred KB a row. Measured: 5 KB for the Guardian's
  140 against 236 KB for The Verge's undeclared original.
- Feed image URLs go through `unescapeAmpersands`, because The Verge escapes `&` numerically
  *inside* already-escaped summary HTML — `&amp;` alone leaves `?quality=90&#038;strip=all`,
  which hands the server a parameter called `#038;strip`.
- An `<img>` declaring width or height of 1 is skipped: that is a tracking beacon, not a
  picture.
- `window.readerRevealThumbs` is the **only** thing that ever sets a thumbnail's `src`, and it
  refuses while `data-thumbs="off"`. Rows render carrying `data-src` alone — server-side for
  recents, in the host callback for suggestions — so "images off" really means the page makes
  no requests. Suggestion rows must still be *built* with the element while the setting is
  off, or toggling back on leaves a reserved column with nothing to put in it; a test pins
  that there is exactly one assignment of `src` in the page.
- A recents row's thumbnail is the article's own `og:image`, captured from the **live**
  document (Readability's result has no image field, and the vendored copy is not ours to
  patch) and stored on `ReaderHistory.Entry`, not in `ArticleCache` — the cache is evictable,
  so a row would outlive its thumbnail. No first-body-`<img>` fallback: that is usually a logo
  or a tracking pixel. The key is omitted rather than written as null when absent, so a blob
  from before the feature round-trips unchanged.
- Thumbnails carry `data-src`, never `src`: the appearance script is the only thing that sets
  a src, so **with article images off the start page requests nothing** — which is what it did
  before, the start page having been entirely offline. `data-thumbs="off"` is baked by
  `themeAttribute` (like `data-quotes`) so nothing flashes before the script runs.
- Rows are a grid, and only in a list that has at least one image (`.has-thumbs`), with the
  text column pinned: an article that named no image still lines its title up with the rest.
  A flex row would have moved `.recent-host` from below the title to beside it, and `float`
  cannot work because the clamped title is a `-webkit-box`.
- A row in such a list whose article named no image gets `thumbnailPlaceholder` — the same box
  in `--surface` with a quiet picture glyph — not a gap. Coverage is uneven by nature, so
  lists normally mix the two and a blank column reads as a failed load. A list where *nothing*
  has an image gets neither images nor placeholders and is laid out exactly as before, which
  is also the state right after upgrading. A failed image swaps itself for the placeholder
  rather than leaving the browser's broken-image glyph.
- The placeholder markup is one Swift constant, handed to the page script through
  `HTML.jsString` so the server-rendered recents rows and the host-delivered suggestion rows
  cannot drift. `HTML.jsLiteral` is NOT interchangeable: it takes an already-serialised
  expression and does not quote, so a bare string through it emits raw markup mid-statement
  (which is exactly the `SyntaxError` it caused first time round).
- The cover's label is a `CAGradientLayer` masked by a `CATextLayer` on macOS and cairo text
  filled with a moving linear gradient on Linux, both driven by `LoadProgress.coverLabelSize`
  / `coverShimmerPeriod` / `coverShimmerSpread` so neither host shimmers at its own speed.
  Sweeping the stops past both ends works because a gradient layer (and `CAIRO_EXTEND_PAD`)
  holds its end colours, so the word stays fully painted in `--muted` and only the `--fg`
  band moves. The CSS equivalent, `background-clip: text`, goes *transparent* past the ends
  and has to tile the gradient to avoid the word vanishing — worth knowing if this is ever
  ported to a page. Both hosts hold the label still when the system asks for reduced motion,
  and stop the animation when the cover comes down.
- Reset Reader Appearance clears settings + zoom, never history (user data, no undo).
- `ProgressLine.height` and `ReaderChrome.progressCSS` both read
  `LoadProgress.lineThickness` — one constant, so a new host can't drift. The two lines are
  deliberately *different colours* (accent for the native page load, `--fg` for the reader's
  scroll progress) so an accent hairline parked mid-page never looks like a stuck load.
- **The Linux `load_html` hazard.** `WKWebView` hands back a `WKNavigation` to identify a
  load; WebKitGTK hands back nothing, and `webkit_web_view_load_html` reports the `base_uri`
  you passed as the view's URI — so our own reader render is indistinguishable *by URI* from
  a real navigation to that article. `PageState.willShow` immediately before the single
  `load_html` call site is therefore the load-bearing mechanism, not a nicety. Related: on
  Linux `load-failed` must return `TRUE` (or WebKit paints its own error page) and must not
  render, because the `load-changed`/FINISHED that always follows would consume the state the
  render just set — it records the failure and lets that FINISHED show the fallback.
- `Theme.auto` on Linux follows the active Omarchy theme, read from
  `~/.local/state/omarchy/current/theme/colors.toml` (the older `current/theme` symlink some
  docs describe is gone). Omarchy's `muted` key is a **UI dim colour**, not a text colour —
  mapping it onto `--muted` measured 2.45:1 on `last-horizon`, so secondary text is a
  foreground→background blend stepped back until it clears WCAG AA instead. `--border` and
  `--surface` have no Omarchy counterpart and are rgba overlays of the foreground. Off
  Omarchy `current()` returns nil and the page falls back to `prefers-color-scheme`.
- GTK4 uses the **GApplication id** as the Wayland `app_id`, so the window class is
  `dk.yepz.webreader`, not `webreader`. `StartupWMClass` and any Hyprland `windowrule` must
  use the id; the executable name silently never matches.
- The Linux window title follows the document via `notify::title`, and that is the only
  writer. macOS sets its title once and leaves it. Two writers is how it went stale.
- Sync is **one file per device, and only that device writes it**. A folder synced by the
  Nextcloud client (or iCloud Drive, or Syncthing) resolves collisions per file: two
  instances writing one `history.json` produce `history (conflicted copy …).json` and lose
  a write. Single-writer files have no collision to resolve, and merging is a fold.
- Every stored timestamp goes through `Timestamp` — whole milliseconds, quantized on write
  *and* on read. They are compared for equality after a JSON round-trip (a cycle publishes
  only when its state differs from the file it last wrote), and full `Double` precision does
  not survive that trip identically on both platforms: corelibs-Foundation prints one
  significant digit fewer than Darwin, so `…957.1707573` came back `…957.1707568` and every
  device rewrote its file on every cycle. The Linux CI job is what caught it.
- Recents carry `readAt` and history carries a `clearedAt` tombstone because two devices
  can't otherwise be ordered against each other. Rows with no `readAt` (everything written
  before sync existed) sort last and are dropped by any tombstone — that's what stops a
  device that was off during a "Clear history" from restoring the list. Zoom is not synced:
  it depends on the screen.
- The settings timestamp lives in its own key (`reader.settings.updatedAt`), NOT inside the
  settings JSON — that JSON is also the reader page's script seed, and the page posts it
  back. `resetAppearance` stamps it too, so a reset propagates instead of losing to another
  device's older settings.
- A cycle never creates the folder the user chose (only the `WebReader` subfolder inside
  it): recreating it would publish into a path nothing syncs, which looks like working sync
  while the devices drift apart. `SyncController.resolveFolder` covers the three ways a
  folder moves — renamed (the bookmark follows), deleted and recreated at the same path (a
  sync client does this routinely; the recorded path takes over), and simply gone (the
  folder stays configured, every trigger retries, the sheet says why).
- The folder is watched twice over: the directory for files appearing, vanishing or being
  replaced, and each peer's file for a client that rewrites it in place — a directory watch
  never sees that. Watchers are re-armed after every cycle. `SyncController` is not
  `NSObject`-derived, so a target/selector `Timer` on it silently never fires; use blocks.
- A merge updates the visible page in place — `window.readerApplySettings(json)` and
  `window.readerSetRecents(rows)` — instead of re-rendering it. The start page holds a URL
  field, and re-rendering under someone mid-sentence throws their typing away.
- Sync is **not on Linux yet** (#35): `ReaderKit/Sync` is portable and both Apple hosts run
  it through the same `ReaderSyncController`, but the GTK host has no folder chooser, so
  `SettingsPage` renders its Sync section only where the host passes a summary. A dead
  control would be worse than none.

## Build & test

```sh
swift build
swift test                       # XCTest; ReaderKit, plus ReaderWebKit's wiring on a Mac
Scripts/build-app.sh             # macOS: build/WebReader.app, ad-hoc signed
Scripts/build-app.sh --install   # …and replace /Applications/WebReader.app
open -a build/WebReader.app https://example.com/article
Linux/install-local.sh           # Linux: release build into ~/.local, registers the handler
.build/debug/webreader https://example.com/article

# iOS: build, install on a booted simulator, run
xcodebuild -project WebReader.xcodeproj -scheme WebReaderiOS -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/WebReader.app
xcrun simctl launch booted dk.yepz.webreader
xcrun simctl io booted screenshot /tmp/shot.png
# Hand it a link the way the share extension does — `simctl openurl` needs a tap to confirm:
group=$(xcrun simctl get_app_container booted dk.yepz.webreader groups | cut -f2)
xcrun simctl spawn booted defaults write \
  "$group/Library/Preferences/group.dk.yepz.webreader" reader.pendingOpen -string https://…

# Android: the .so and its runtime first, then the APK. The open-source Swift toolchain is
# mandatory — Xcode's cannot cross-compile at all, and reports the same version number while
# producing incompatible .swiftmodule files, so the failure reads as "rebuild Foundation".
ABIS="aarch64-unknown-linux-android28 x86_64-unknown-linux-android28" Scripts/build-android.sh
(cd android && ./gradlew :app:assembleDebug)
adb install -r android/app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
adb shell am start -n dk.yepz.webreader/.MainActivity -a android.intent.action.SEND \
  -t text/plain --es android.intent.extra.TEXT "https://example.com/article"
adb exec-out screencap -p > /tmp/shot.png
```

`Package.swift` guards the AppKit host and `ReaderWebKit` behind `#if os(macOS)` and the
`CWebKitGTK` + `WebReaderGTK` targets behind the `#else`, so `swift build`/`swift test` do the
right thing on either OS and neither branch can break the other. Android is `WEBREADER_ANDROID=1`
in the environment instead of a third `#if`, because the manifest is compiled and *run on the
build machine*: `os()` names the Mac or the Linux box driving the cross-compile, never the
phone, so an `#if os(Android)` branch would be dead while the `#else` wrongly claimed the
build and demanded GTK. On Linux, `Suggestions.swift` and `FeedFetcher.swift` need
`FoundationXML`/`FoundationNetworking` — corelibs splits `XMLParser` and `URLSession` out of
Foundation proper. Linux needs `gtk4` and `webkitgtk-6.0` (both in Arch `extra`) and a Swift
toolchain, which on Arch is the AUR `swift-bin`.

The GTK host has no test target; the AppKit shell has none either, but the WKWebView half it
used to contain now does — `Tests/ReaderWebKitTests` drives a real off-screen `WKWebView`,
clicks the real generated pages and asserts what lands in the store. What is left in
`AppDelegate` (menu, window, clipboard, zoom) is still verified by hand. Verify the GTK host
by running it: the `GtkApplication` exports its action map on D-Bus, so
`gdbus call --session --dest dk.yepz.webreader --object-path /dk/yepz/webreader --method
org.gtk.Actions.Activate "settings" "[]" "{}"` drives an accelerator without synthesising key
events, and `hyprctl clients` reports the window title, which follows the document.

Bundle metadata lives in `App/Info.plist` (bundle id `dk.yepz.webreader`, http/https handler)
and `App/AppIcon.icns` for the Mac, and in `App/iOS/` for the phone: `Info.plist` (the
`webreader` URL scheme), `Share-Info.plist` (the share extension's activation rule) and two
`.entitlements` files carrying the App Group. `WebReader.xcodeproj` builds only the iOS app
and its extension — it is objectVersion 77, so it needs Xcode 16 or newer, and its sources
arrive through synchronized folder groups rather than per-file build entries. The Mac keeps
`build-app.sh` and the notarized release path it feeds; that pipeline never sees Xcode.

Two version numbers now exist: `App/Info.plist`'s `CFBundleShortVersionString`, which
`Scripts/release.sh` treats as the source of truth, and the project's `MARKETING_VERSION`,
which the iOS plists interpolate. Nothing keeps them in step automatically — bump both.

Test pattern: keep logic pure and test it; keep WebKit/AppKit orchestration thin. New
non-trivial logic gets one small XCTest, not a suite. Design: no emoji in the UI, inline SVG
line icons, one accent color, subtle radii — `OfflineFallbackTests.testNoEmojiInPage` guards
one of those.

## Release process

Releases are built, signed, and notarized **on the maintainer's Mac** (the Developer ID
certificate and notarization credentials live in its keychain — nothing is exported to CI),
then published as a GitHub Release and a Homebrew cask.

1. PR `chore: release X.Y.Z`: bump `CFBundleShortVersionString` in `App/Info.plist` and roll
   `[Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z] - YYYY-MM-DD`. Merge it.
2. `git checkout main && git pull && Scripts/release.sh`. The script refuses to run off a
   clean `main`, without a matching CHANGELOG section, or if the tag exists. It builds a
   universal binary via `Scripts/build-app.sh` with the hardened runtime, notarizes with
   `xcrun notarytool` (keychain profile `webreader`; override with `NOTARY_PROFILE`), staples,
   zips, and runs `gh release create vX.Y.Z` with the CHANGELOG section as notes.
3. It then runs `Scripts/update-cask.sh X.Y.Z <sha>`, which rewrites `Casks/webreader.rb` in
   the `yepzdk/homebrew-tools` tap and pushes. If only that step fails, re-run it by hand
   with the arguments the script printed.

Contracts: the release asset **`WebReader.zip` keeps that exact name** — the blog and README
link `releases/latest/download/WebReader.zip`. The cask pins `WebReader-X.Y.Z.zip` by sha.

One-time setup on a new Mac: import the Developer ID certificate, then
`xcrun notarytool store-credentials webreader --apple-id <id> --team-id 96DL4CMTDZ`.

## Conventions

- Never commit to `main`. Branch as `feature/issue-{number}-{description}`.
- Conventional Commits; `Co-authored-by: Claude <noreply@anthropic.com>` trailer.
- `CHANGELOG.md` follows Keep a Changelog; update `[Unreleased]` with every change.
- English for code, comments, commits, docs.
