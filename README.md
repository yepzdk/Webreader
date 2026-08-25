# WebReader

A small macOS reading app. Send it a link — from a browser picker like [Choosy](https://www.choosy.app/), `open -a WebReader <url>`, or the clipboard — and it renders the article as a clean, distraction-free page: title, byline, body. No ads, no site chrome.

Reader extraction is [Mozilla Readability](https://github.com/mozilla/readability), the library behind Firefox's reader view. It runs on the rendered page inside the app's own session, so articles behind a login you're signed in to extract correctly.

WebReader started life as a [webwrap](https://github.com/yepzdk/webwrap)-generated app and was split out into its own project in August 2026.

## Install

There's no release yet — build it yourself (Xcode command-line tools, macOS 13+):

```sh
git clone https://github.com/yepzdk/webreader.git
cd webreader
Scripts/build-app.sh --install     # builds build/WebReader.app and copies it to /Applications
```

The bundle is ad-hoc signed. Set `SIGN_IDENTITY="Developer ID Application: …"` to sign with the hardened runtime instead.

## Using it

**Getting links in.** WebReader registers as an `http`/`https` handler, so a browser picker can route links to it, and `open -a WebReader https://…` works from the shell. For a page a browser is already showing (which a picker can't intercept), copy the URL and press **⇧⌘O** in WebReader — or paste it into the field on the start page.

Incoming links are cleaned first: tracking redirects that embed the real destination (newsletter click-trackers, Google/Facebook/SafeLinks) are unwrapped and tracking parameters (`utm_*`, `fbclid`, …) stripped, so the app never contacts the tracking host.

**Reading.** Every page that looks like an article opens as a reader page; pages that don't load normally. **⇧⌘R** (View → Toggle Reader View) switches between the reader rendering and the original page. A hairline along the top edge fills as you scroll, so a long article's remaining length is visible at a glance.

**Appearance.** The **Aa** button in the top-right corner sets font size, serif or sans type, column width, line height, and theme (auto, light, sepia, dark, black). Changes apply instantly and persist. **⌘+ / ⌘− / ⌘0** zoom any page. View → Reset Reader Appearance returns everything to stock.

**Recents.** The list button next to **Aa** opens the last 30 articles read; click one to reopen it in the reader. The start page (**⇧⌘H**) lists the same articles inline. Clear history from the bottom of the panel — Reset Reader Appearance leaves it alone.

**Paywalls.** To get full text from a site that paywalls logged-out visitors, log in once inside the app (⇧⌘R to the original page, sign in). The session persists.

| Shortcut | Action |
|---|---|
| ⇧⌘O | Open URL from clipboard |
| ⇧⌘R | Toggle reader view |
| ⇧⌘H | Home (start page) |
| ⇧⌘C | Copy current URL |
| ⌘R | Reload |
| ⌘+ / ⌘− / ⌘0 | Zoom |
| ⌘[ / ⌘] | Back / forward |

## Coming from the webwrap-generated WebReader

On first launch, WebReader imports your appearance settings, recents, and zoom from the old app (`dk.yepz.webwrap.webreader`). Site logins live in the old app's WebKit store and don't carry over — sign in again once. Replacing `/Applications/WebReader.app` with this build is the intended path; `webwrap list` will stop listing it.

## Development

```sh
swift build            # debug build of ReaderKit + the WebReader executable
swift test             # ReaderKit unit tests
Scripts/build-app.sh   # assemble build/WebReader.app
```

The package has two targets: **ReaderKit** — Foundation-only reader logic (article model, appearance settings, recents, the generated reader/start/offline pages, URL cleaning) that a future iOS app shares — and **WebReader**, the AppKit host. See `CLAUDE.md` for the architecture notes.

## License

MIT. Readability is vendored under the Apache License 2.0 (see `Sources/ReaderKit/ReadabilityJS.swift`).
