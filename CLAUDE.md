# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

WebReader is a macOS reading app: it receives links (browser picker, `open -a`, ⇧⌘O, start
page) and renders articles as a clean reader page via Mozilla Readability. It was split out
of [yepzdk/webwrap](https://github.com/yepzdk/webwrap) in August 2026; webwrap's reader is
frozen at 0.8.0 and all reader work happens here.

Roadmap (not started): read-aloud (`AVSpeechSynthesizer` over Readability's `textContent`),
a feed of similar articles, and an iOS/iPadOS app with sync (`NSUbiquitousKeyValueStore` for
settings + recents first; CloudKit only if article bodies need to sync).

## Architecture

Two SwiftPM targets, no dependencies:

- **`Sources/ReaderKit`** — Foundation-only. Must stay free of AppKit/WebKit/UIKit so the
  future iOS target can depend on it unchanged. Everything here is pure string/JSON work
  and unit-tested:
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
  - `SettingsPage.swift` — the suggestion sources and the language filter (⌘,).
  - `HiddenPhrases.swift` — boilerplate phrases removed from articles (cap 100) and the JS
    `readerHideBlocks` that does it, shared by the extraction script and the live reader page.
  - `StartPage.swift`, `OfflinePage.swift` (`OfflineFallback` + `HTML.escape`).
  - `URLCleaner.swift` — tracking-redirect unwrap / tracking-param strip (ported from
    yepzdk/url-cleaner; never unwraps OAuth `redirect*` params or unencoded nested URLs).
  - `WebURL.swift` — `isWebURL`, `loadsInApp`, `clipboardURL`, `urlToCopy`.
  - `ReaderStore.swift` — `KeyValueStore` protocol, `DefaultsStore`, and the keys/bounds for
    settings, history, and zoom. Strings only, so a KVS-backed store can drop in for sync.
  - `ReadabilityJS.swift` — vendored Readability 0.6.0 as string literals (Apache-2.0). To
    upgrade, replace both literals and bump `version`.
- **`Sources/WebReader`** — the AppKit host. `AppDelegate.swift` owns the window, `WKWebView`,
  menu, URL handling (`application(_:open:)` + the GetURL Apple Event), the reader state
  machine, offline fallback, and the script-message handlers. `ProgressLine.swift` is the
  native load-progress hairline. `LegacyImport.swift` is the one-time import from the
  webwrap-generated app's defaults domain (`dk.yepz.webwrap.webreader`).

### Rules that aren't obvious from the code

- The reader renders as its **own document** (`loadHTMLString(_:baseURL:)` with the article
  URL as base), never an in-place DOM swap — hydrating sites revert swaps within a second.
- Page state (`isShowingStartPage`, `isShowingFallback`, `isShowingReader`,
  `pendingReaderRender`) is tracked with explicit flags, not inferred from `webView.url`. The
  flags also gate every script message handler so a live site can't post to them.
- Generated pages talk to the host via `readerRetry`, `readerSettings`, `readerOpen`,
  `readerClear`, `readerOpenURL`, `readerUnhide`, `readerOpenSettings`, `readerHome`,
  `readerAddSource`, `readerRemoveSource`, `readerSetLanguages`. Rename in both Swift and the
  page scripts together. The host calls back via `window.readerSetHidden(list)`,
  `window.readerSetSuggestions(items)`, `window.readerSourceAdded/Rejected(…)`.
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
- Every generated page carries a `<meta name="generator">` — `WebReader` (reader, matched
  EXACTLY by the extraction script), `WebReader Start`, `WebReader Settings`. They are real
  back/forward entries, so `didStartProvisionalNavigation` clears the page flags and
  `didFinish` re-establishes them by reading the marker; without that, ⌘[ off Settings left
  every start-page handler gated shut.
- The start page renders before suggestions exist: the section ships hidden and empty, the
  host fills it via `window.readerSetSuggestions` when the fetch lands, and the task is
  cancelled on any navigation away. Nothing about suggestions can block or fail the page.
- Reset Reader Appearance clears settings + zoom, never history (user data, no undo).
- `ProgressLine.height` (2.5pt) and `ReaderChrome.progressCSS` (2.5px) are kept in step by
  hand; they can't share a constant across the Swift/CSS boundary.

## Build & test

```sh
swift build
swift test                       # XCTest; ReaderKit only — AppKit wiring is verified by hand
Scripts/build-app.sh             # build/WebReader.app, ad-hoc signed
Scripts/build-app.sh --install   # …and replace /Applications/WebReader.app
open -a build/WebReader.app https://example.com/article
```

Bundle metadata lives in `App/Info.plist` (bundle id `dk.yepz.webreader`, http/https handler)
and `App/AppIcon.icns`. There is no Xcode project yet; it arrives with the iOS target, at
which point `build-app.sh` retires.

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
