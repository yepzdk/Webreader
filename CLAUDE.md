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
  `readerClear`, `readerOpenURL`, `readerUnhide`. Rename in both Swift and the page scripts
  together. The host calls back into the reader page via `window.readerSetHidden(list)`.
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
  reappears after ⌘R (re-extract). Cached renders still go through `renderReader`, so they
  record history and re-store like a live one.
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
