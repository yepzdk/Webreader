# WebReader

[![Release](https://img.shields.io/github/v/release/yepzdk/webreader?label=release)](https://github.com/yepzdk/webreader/releases/latest)
[![CI](https://github.com/yepzdk/webreader/actions/workflows/ci.yml/badge.svg)](https://github.com/yepzdk/webreader/actions/workflows/ci.yml)
[![Buy me a coffee](https://img.shields.io/badge/Buy_me_a_coffee-yepzdk-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/yepzdk)

A small reading app for macOS, Linux, iPhone, iPad and Android. Send it a link — from a browser picker like [Choosy](https://www.choosy.app/) on macOS or the browser chooser on Linux, from the share sheet on iOS and Android, from the shell with `open -a WebReader <url>` or `webreader <url>`, or from the clipboard — and it renders the article as a clean, distraction-free page: title, byline, body. No ads, no site chrome.

Reader extraction is [Mozilla Readability](https://github.com/mozilla/readability), the library behind Firefox's reader view. It runs on the rendered page inside the app's own session, so articles behind a login you're signed in to extract correctly.

WebReader started life as a [webwrap](https://github.com/yepzdk/webwrap)-generated app and was split out into its own project in August 2026.

## Install

macOS 13 or later, Apple Silicon or Intel. Releases are signed with a Developer ID and notarized, so they open without a Gatekeeper detour.

```sh
brew install --cask yepzdk/tools/webreader
```

Or download the latest [`WebReader.zip`](https://github.com/yepzdk/webreader/releases/latest/download/WebReader.zip) and drag the app to Applications. Versioned zips and checksums are on the [releases page](https://github.com/yepzdk/webreader/releases).

To build it yourself instead (Xcode command-line tools):

```sh
git clone https://github.com/yepzdk/webreader.git
cd webreader
Scripts/build-app.sh --install     # builds build/WebReader.app and copies it to /Applications
```

A self-built bundle is ad-hoc signed, so it runs on the Mac that built it. Set `SIGN_IDENTITY="Developer ID Application: …"` to sign with the hardened runtime instead.

On iPhone and iPad there is no release yet: build and run it from `WebReader.xcodeproj` (Xcode 16 or newer, iOS 16 or later). Share a link to WebReader from Safari's share sheet, or open `webreader://open?url=…` from Shortcuts. Settings and recents follow the Mac's if you point both at the same sync folder.

On Android there is no release yet either: run `Scripts/build-android.sh` to cross-compile the reader and its Swift runtime, then `cd android && ./gradlew :app:assembleDebug`. The app registers for `http`/`https` and for the share sheet. See [`android/README.md`](android/README.md).

On Linux it is developed against Arch with Hyprland — an [Omarchy](https://omarchy.org/) desktop — and needs `gtk4` and `webkitgtk-6.0`, both in the official `extra` repository:

```sh
sudo pacman -S --needed gtk4 webkitgtk-6.0
paru -S webreader                  # or whichever AUR helper you use
```

To build from a checkout instead, into `~/.local` and nowhere else:

```sh
git clone https://github.com/yepzdk/webreader.git
cd webreader/Linux
./install-local.sh                 # binary, .desktop entry and icon under ~/.local
```

Either way the build wants a Swift toolchain, and Arch does not carry one in its own repositories — it comes from the AUR as `swift-bin`, a repack of the official swift.org tarball. That is the honest price of writing the host in Swift: the two runtime dependencies are stock, the build dependency is not.

## Using it

**Getting links in.** WebReader registers as an `http`/`https` handler, so a browser picker can route links to it, and `open -a WebReader https://…` works from the shell. For a page a browser is already showing (which a picker can't intercept), copy the URL and press **⇧⌘O** — **Ctrl+Shift+O** on Linux — in WebReader, or paste it into the field on the start page.

Incoming links are cleaned first: tracking redirects that embed the real destination (newsletter click-trackers, Google/Facebook/SafeLinks) are unwrapped and tracking parameters (`utm_*`, `fbclid`, …) stripped, so the app never contacts the tracking host.

**Reading.** Every page that looks like an article opens as a reader page; pages that don't load normally. **⇧⌘R** (View → Toggle Reader View) switches between the reader rendering and the original page. A hairline along the top edge fills as you scroll, so a long article's remaining length is visible at a glance.

**Appearance.** The **Aa** button in the top-right corner sets font size, serif or sans type, column width, line height, theme (auto, light, sepia, dark, black), and how inline quotations (»…«, “…”) are set — bordered with medium weight, or italic. Changes apply instantly and persist. **⌘+ / ⌘− / ⌘0** zoom any page. View → Reset Reader Appearance returns everything to stock.

**While a page loads** you get a plain screen rather than the site you asked not to read, with the load progress along the top edge. It stays until the article is ready — however long that takes, as long as the connection is still doing something — and steps aside if the page turns out not to be an article.

**Getting back.** Every page except the start page has a Home button in the same top-left corner (**⇧⌘H** / **Ctrl+Shift+H** does the same) — the reader, Settings, and the offline page, so a failed load is never a dead end. On the start page that corner holds **Settings** instead.

**Recents.** The list button next to **Aa** opens the last 30 articles read; click one and it opens instantly from its saved copy, offline too, for as long as the system keeps it (copies live in the cache folder). If a page fails to load and a saved copy exists, you get the copy instead of the error page. **⌘R** in the reader fetches the page again. The start page (**⇧⌘H**) lists the same articles inline. Clear history from the bottom of the panel (this also deletes the saved copies) — Reset Reader Appearance leaves it alone.

**Hidden text.** Boilerplate lines that survive extraction — "Artiklen fortsætter efter annoncen", "Advertisement" and the like — are removed. A paragraph is dropped only when its entire text is one of the phrases, never when it merely contains one. Teach it new ones as you read: select the sentence in the reader and press the **Hide text** button that appears beside it. It disappears immediately and from every article after that. The eye-off button next to **Aa** shows how many blocks the current article lost and lists the phrases — the ones that hit this article first, with their count — each with a remove control.

**Article images.** Rows on the start page carry a small thumbnail where the article has a lead image. For recents it comes from the page you read (`og:image`); for suggestions it comes from the feed (`media:thumbnail`, `media:content`, an image `enclosure`, or the first picture in the item's summary). Not every feed publishes one — wallnot.dk, the shipped source, publishes none — so some rows will have no image; those get a placeholder, and stay lined up with the rest. A list where nothing has an image looks exactly as it did before. Turn them off with **Aa → No images**: with the setting off the page asks the publishers for nothing at all. Thumbnails are requested without a referrer, and only over `http`/`https`.

**Suggestions.** The start page lists a few articles you might want next, ranked against what you have been reading — no accounts, no tracking, all on-device. It ships with one source: [wallnot.dk](https://wallnot.dk), a non-commercial Danish index of articles without paywalls, so there is something to read on the first launch. **⌘,** opens Settings, where you can add your own sources (a feed address, or a site address to look one up on), remove any of them including the shipped one, and — once your sources span more than one language — limit suggestions to the languages you read.

Suggestions are ranked against what you have been reading, and you can steer them: hover a suggested article for **More like this** / **Less like this**, or block the outlet entirely with **×** — no more articles from `extrabladet.dk`, whichever source carries them. The same thumbs sit in the reader's top-right corner, so you can say it about the article you are actually reading; they light up to show your opinion, and clicking again takes it back. Blocked outlets are listed in Settings, where you can lift a block again. When the window is wide enough, recents and suggestions sit side by side.

Fetching suggestions contacts the sources themselves and nothing else; what you read never leaves the machine.

**Paywalls.** To get full text from a site that paywalls logged-out visitors, log in once inside the app (⇧⌘R to the original page, sign in). The session persists.

**Sync (Mac).** Settings (**⌘,**) has a **Sync** section — or **Sync…** in the WebReader menu — that keeps appearance settings and recents in step across Macs: pick a folder that already syncs between your devices (one inside your Nextcloud folder, iCloud Drive, Syncthing, anything) and every copy of WebReader pointed at it stays current. No account, no server address, no password: WebReader only writes files, and whatever syncs the folder moves them.

Each device writes one small JSON file of its own and reads the others, so two devices reading at the same time can't collide (no "conflicted copy" files) and neither can overwrite the other's list — recents merge, newest first, and clearing history clears it everywhere, including on a device that was switched off at the time. Appearance is last-writer-wins; page zoom stays local, since it depends on the screen. The sheet shows when the last sync happened, which other devices it can see, and what went wrong if the folder is missing. The Linux app doesn't offer sync yet.

| macOS | Linux | Action |
|---|---|---|
| ⇧⌘O | Ctrl+Shift+O | Open URL from clipboard |
| ⇧⌘R | Ctrl+Shift+R | Toggle reader view |
| ⇧⌘H | Ctrl+Shift+H | Home (start page) |
| ⇧⌘C | Ctrl+Shift+C | Copy current URL |
| ⌘, | Ctrl+, | Settings |
| ⌘R | Ctrl+R | Reload |
| ⌘+ / ⌘− / ⌘0 | Ctrl++ / Ctrl+− / Ctrl+0 | Zoom |
| ⌘[ / ⌘] | — | Back / forward |

The Linux chords are Ctrl-based on purpose: Hyprland keeps its own bindings on Super, so the two sets never reach for the same keys. Back and forward are not host actions there — whatever the web view does with Alt+← and the mouse's side buttons is WebKitGTK's own behaviour.

## Linux

**Getting links in.** The installed `.desktop` file registers `http` and `https`, so WebReader turns up in the browser chooser and `xdg-settings` will accept it as a default-web-browser value. Installing it does not make it your default, deliberately: neither the package nor `install-local.sh` writes to `mimeapps.list`. Making it the default is a decision you take, with a command the installer has no business running for you:

```sh
xdg-settings set default-web-browser dk.yepz.webreader.desktop
```

**No menu bar.** The GTK host has none, and that is a choice rather than an omission. Hyprland owns quit and the window verbs, WebKitGTK owns the edit verbs inside the page, and appearance, recents and settings already have their own controls in the web shell — a menu bar would be a second, worse copy of all three. What is left is the handful of host actions, and on a keyboard-first desktop those are better as accelerators. Because there is then nowhere to read them off, the settings page lists them.

**Opening a link from anywhere.** Ctrl+Shift+O reads a URL from the clipboard, but only while WebReader has focus — which is precisely when you least need it. On macOS ⇧⌘O reaches the app from the background; on Wayland an application cannot grab a global key for itself, so Hyprland invokes the flag on its behalf. Add the binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + ALT + O", "Read clipboard URL", "webreader --clipboard")
```

Hyprland reloads on save, so it is live the moment you write the file. `SUPER + SHIFT + ALT + O` is free on a stock Omarchy box; `omarchy menu keybindings --print` will tell you if you have since claimed it for something else. Copy a link in any window, press it, and the article opens.

**Themes.** Auto — the default — follows the desktop. On Omarchy it reads the active theme's palette from `~/.local/state/omarchy/current/theme/colors.toml`, so the reader is the same colour as the rest of the session; switch with `omarchy theme set …` and the reader follows on the next page render. Light, sepia, dark and black still pin their own palette and ignore the desktop. On a machine without Omarchy there is no `colors.toml` to read, and auto falls back to the system's light/dark preference.

**Fonts.** The reader asks for Noto Serif and Adwaita Sans, which is what a stock Omarchy box actually resolves. There is no New York shipping with the OS here, so the app aims at fonts that are already present rather than at one it would have to carry itself. If you want a nicer reading serif than Noto, that is a packaging matter and not an app setting: install the font and let fontconfig prefer it.

## Coming from the webwrap-generated WebReader

On first launch, WebReader imports your appearance settings, recents, and zoom from the old app (`dk.yepz.webwrap.webreader`). Site logins live in the old app's WebKit store and don't carry over — sign in again once. Replacing `/Applications/WebReader.app` with this build is the intended path; `webwrap list` will stop listing it.

## Development

```sh
swift build            # debug build of ReaderKit and this platform's host
swift test             # ReaderKit unit tests
Scripts/build-app.sh   # assemble build/WebReader.app (macOS)
```

The package has three SwiftPM targets on a Mac: **ReaderKit** — Foundation-only reader logic, including `ReaderSession`, which is what the app actually decides (page state, extraction, the seventeen script messages) expressed as commands a host runs — **ReaderWebKit**, the WKWebView adapter shared by the Apple hosts, and **WebReader**, the AppKit shell around it. Linux swaps the last two for **CWebKitGTK**, a system-library shim over GTK4 and WebKitGTK 6.0, and **WebReaderGTK**, which produces the `webreader` binary. `Package.swift` guards the AppKit host and ReaderWebKit behind `#if os(macOS)`, so on Linux `swift build` and `swift test` cover ReaderKit and the GTK host and nothing reaches for AppKit or WebKit. `WEBREADER_ANDROID=1` selects a third set — **ReaderKitAndroid** and **CReaderKitJNI** — that cross-compiles the same ReaderKit into a `.so` for the Kotlin host under `android/`. The iOS app and its share extension (`Sources/WebReaderiOS`, `Sources/WebReaderShare`) are built by `WebReader.xcodeproj`, which consumes the same package. `Scripts/build-app.sh` and `Scripts/release.sh` stay macOS-only — they codesign and notarize, which has no Linux counterpart. See `CLAUDE.md` for the architecture notes.

## Support

WebReader is free and open source. If it saves you from a few cookie banners a day, you can [buy me a coffee](https://buymeacoffee.com/yepzdk).

## Privacy

Nothing is collected. No account, no analytics, no tracking, no third-party SDKs — see
[PRIVACY.md](PRIVACY.md).

## License

MIT. Readability is vendored under the Apache License 2.0 (see `Sources/ReaderKit/ReadabilityJS.swift`).
