# App Store listing

Everything App Store Connect asks for, written down so a submission is a copy-and-paste
rather than a re-invention. Character limits are Apple's and are counted here.

Screenshots are generated, not hand-made: `Scripts/screenshot-pages.swift` writes the
pages and the capture recipe is at the end of this file.

## App information

| Field | Value | Limit |
| --- | --- | --- |
| Name | `WebReader` | 30 |
| Subtitle | `The article, distraction free` | 30 |
| Bundle ID | `dk.yepz.webreader` | — |
| SKU | `webreader` | — |
| Primary category | Productivity | — |
| Secondary category | News | — |
| Primary language | English (U.S.) | — |
| Support URL | `https://github.com/yepzdk/webreader` | — |
| Marketing URL | *(leave empty)* | — |
| Privacy policy URL | `https://github.com/yepzdk/webreader/blob/main/PRIVACY.md` | — |
| Copyright | `2026 Jesper Pedersen` | — |

## Promotional text (170)

Editable without a new build, so this is the line to change when something ships.

```
Paste a link and read the article in a typography you control. No cookie banners, no
newsletter overlays, no tracking. Your reading stays on your devices.
```

## Description (4000)

```
WebReader strips a web page back to the article and renders it in a typography you
control.

Paste or share a link and you get the text, the byline and the images that belong to the
story. No cookie banner, no newsletter overlay, no floating share bar.

TYPOGRAPHY YOU SET
Serif or sans, four text sizes, three column widths, three line heights, and four themes —
light, sepia, dark and black. Links can be as loud or as quiet as you like: a bright
colour, a hushed one, a whisper of colour in the ink, or nothing but an underline. Every
colour in the app is contrast-checked against every theme.

READING, NOT A FEED
Add the sites you already read and WebReader suggests what is new, ranked against what you
have read rather than against what someone wants you to see. Three suggestions at the end
of every article. No algorithm you cannot inspect, because there is no server: the ranking
happens on your device.

YOUR READING IS YOURS
Nothing is collected. No account, no analytics, no tracking, no third-party SDKs. Recents
and settings sync through a folder you choose — your Nextcloud folder, iCloud Drive,
anything that already syncs — or nowhere at all, which is the default.

WHEN A PAGE NEEDS ITS SITE
A paywall's sign-in form lives on the site's own page, so one control hands the page back
and remembers that site for next time. Text you never want to see again — a cookie notice,
a subscription pitch — can be hidden by selecting it once.

Also on the Mac, from the same reader code.
```

## Keywords (100, comma-separated, no spaces after commas)

```
reader,readability,article,read later,rss,feed,distraction free,typography,offline,privacy
```

## What's New in 0.14.0

```
Links can now be as quiet as you like: follow the text and let the underline mark them, or
pick a bright, tinted or hushed shade. Every page you look at — the start page and the
reader — has its own appearance popover, with the controls that belong to it.

The app also has an icon of its own, and the first line of an article no longer reads grey
on a desktop.
```

## App Review notes

The one real review risk is guideline 5.2 (intellectual property), because the app
reformats other people's articles. Answer it before it is asked:

```
WebReader renders articles the user chooses to open, on-device, using Mozilla's
Readability — the same approach as Safari Reader. It fetches only pages the user opens or
feeds the user subscribes to, republishes nothing, hosts nothing, and has no server.
Content is never modified or redistributed; it is reformatted for reading on the device
that fetched it.

The app collects no data: no account, no analytics, no tracking, no third-party SDKs.
Reading history and settings stay on the device unless the user points sync at a folder
they own.

No sign-in is required to review the app. Paste any article URL into the field on the start
page, or use the Share sheet from Safari.
```

## Age rating

The questionnaire's **Unrestricted Web Access** item applies — the user can paste any URL —
and answering it honestly gives a **17+** rating. It does not block release; it only sets
the badge. Every other item is None.

## App privacy

**Data Not Collected**, every category. `PRIVACY.md` is the source of truth and the URL
above points at it.

Export compliance is already answered in the build: `ITSAppUsesNonExemptEncryption` is
`false` in `App/iOS/Info.plist`, so no annual paperwork and no encryption questions at
upload.

## Screenshots

App Store Connect names its slots by display size, and a record can be asking for an
older one than the newest device: an app whose iPhone tab shows **6.5"** rejects a 6.9"
frame outright, with the sizes it does want spelled out in the error. Generate all four
and upload whichever the tab in front of you asks for.

| Slot | Pixels (portrait) | Viewport x ratio |
| --- | --- | --- |
| iPhone 6.9" | 1320 x 2868 | 440 x 956 at 3x |
| iPhone 6.5" | 1284 x 2778 | 428 x 926 at 3x |
| iPad 13" | 2064 x 2752 | 1032 x 1376 at 2x |
| iPad 12.9" | 2048 x 2732 | 1024 x 1366 at 2x |

A phone slot uses the phone's pages and a tablet slot the tablet's, whatever the exact
pixel count: the settings are chosen for the screen a reader holds, not for the number.

```sh
WEBREADER_SHOTS=1 swift test --filter ScreenshotPages   # -> build/screenshots/html/
```

Capture each page at the viewport and ratio above **with touch emulation on**: the chrome
collapses into a corner column on a coarse pointer, and a phone screenshot showing the
desktop layout is a screenshot of a layout no phone draws. Strip the alpha channel
afterwards — App Store Connect rejects screenshots carrying one.

Three things the pages do not do by themselves:

- The suggestions arrive from the host at runtime, so call
  `window.readerSetSuggestions([{title, url, source}, …])` first, exactly as a host does.
  Use real headlines.
- The popover frames need the chrome toggle clicked, then `#readerAa`.
- The last frame needs `window.scrollTo(0, document.body.scrollHeight)`.

**No real outlets.** The article, the byline, the headlines and the suggestion rows are
written for the shot, and every host is a reserved example domain. A screenshot is
marketing: one carrying somebody else's masthead borrows their reputation to sell ours,
and goes stale the day their story does. The same goes for this document — nothing here
names a place the app pulls content from.

**Not the simulator, and not for want of trying.** The app can only be steered from
outside through `webreader://open?url=…`, and iOS puts a confirmation dialog in front of a
scheme opened by another process: `simctl openurl` raises "Open in WebReader?" on a cold
start as well as a warm one, `simctl` cannot tap it away, and driving the Simulator window
through System Events needs assistive access this machine does not grant. Capturing the
pages directly is the same markup, CSS and font stack the app ships, at the same pixel
size — what it loses is the status bar, which the store does not ask for.

Order matters; the first two are what a browsing reader sees:

1. An article in the reader.
2. The start page: recents, and suggestions ranked against them.
3. The appearance popover, open. The phone uses the start page's, whose seven rows fit
   where the reader's ten do not; the iPad has room for the reader's.
4. The same article in sepia, a size up.
5. The end of an article: three things to read next.
