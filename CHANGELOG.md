# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Sync appearance settings and recents between devices through a folder you pick — inside
  your Nextcloud folder, iCloud Drive, or anything else that syncs. Each device writes its
  own file, so nothing collides and no device can wipe another's list. Set it up in
  Settings (⌘,) or under Sync… in the WebReader menu; page zoom stays local. Mac only for
  now — the Linux app has no folder picker yet.

### Changed
- **Recents live on the start page** (#32). The start page drops its recents and hidden-text
  buttons: the recents popover duplicated the inline list in a worse form, and the
  hidden-text panel had no article to group phrases against. Clearing history moves under
  the inline list, and hidden phrases are managed on the settings page beside blocked
  outlets.
- **Five recent, five suggested** (#33). The reader's recents popover lists five recent
  articles instead of the whole history, followed by five suggestions — both with
  thumbnails — so you can pick up something new without going home first.
- **Article images move to settings.** The Aa popover's **Images / No images** switch is
  gone: sitting among the type and theme controls it read as governing the article's own
  images, which it never did. The settings page now has an **Article images** section with
  one switch per surface — the start page's lists and the reader's dropdown — and a list
  with its switch off carries no images, reserves no space for them and fetches nothing.
  Anyone who had turned the old switch off gets both new ones off, and Reset Reader
  Appearance now leaves both alone.
- Recents now record when an article was read, and clearing history leaves a timestamp, so
  two devices merge in the right order and a clear isn't undone by a device that was off.
  Existing lists are read as before, on both platforms.
- **The pages work on a touch screen** (#36). Controls reach a 44px target where a finger
  is doing the pointing, popovers stay on screen and clear the safe areas, and the layout
  stops spending desktop gutters and 18vh of headroom on a phone. Groundwork for the mobile
  apps; a roomy desktop window renders exactly as before.
- **On a small viewport the reader's controls move to the bottom-right and hide behind one
  button** (#36). Six always-visible buttons over an article compete with the article, and
  the top edge is the hardest place on a phone to reach one-handed. Tapping the button opens
  a vertical column with Home nearest your thumb; tapping anywhere else, or Escape, closes it
  again. Opening recents, hidden text or Aa collapses the column so only the panel is on
  screen. Every button in the column is the same square, so the start page's Settings button
  shows an icon there instead of its word. Triggered by the size of the window, not by touch
  — so a narrow desktop window gets it too, which is where you can see it before the mobile
  apps exist. A roomy window keeps the controls in both top corners, and Settings keeps its
  word.

### Fixed
- **Suggested-article controls were unreachable without a mouse** (#36). More, Less and
  Block on a suggested row were revealed on hover, which meant they were invisible and
  unusable on any touch screen. They are now visible by default and only hidden where a
  pointer can actually hover.
- **Article text ran through the top buttons while scrolling.** Each button painted its own
  background, but the gaps between them let the article through, leaving a line of text
  crossing the icons with neither readable. A gradient now sits behind them, fading into the
  page so it stays invisible until something scrolls under it, and following the theme. On
  a small viewport the controls have left the top edge entirely, so the problem goes with
  them.

## [0.11.0] - 2026-08-31

### Fixed
- **Keyboard focus** (#26). `Tab` now reaches the whole page on macOS — buttons, recents
  rows, the appearance controls — instead of stopping at the URL field.

### Added
- **A way home** (#15). The reader, settings and offline pages now carry a Home button in the
  top-left corner, aligned with the controls opposite it. On the start page that slot holds
  Settings, which moves up from the bottom-left corner. Settings loses its "Done" button: it
  sat below the fold and committed nothing, since changes there apply as you make them.
- **A loading screen** (#24). While a page loads, WebReader shows a plain screen with the
  progress line at the top instead of letting the original site paint itself only to be
  replaced by the reader a moment later. It picks one of fifteen short messages per load, with
  a highlight travelling across it — held still if the system asks for reduced motion. On a
  slow connection the screen stays up as long as the load keeps moving, and gives way only if
  nothing happens for six seconds.
- **Article thumbnails** (#25). Recent and suggested articles on the start page show the
  article's own lead image where there is one — read from the page for recents, and from the
  feed for suggestions. Articles without one get a placeholder rather than a blank gap, so
  rows stay lined up. Turn them off under **Aa → No images**; with them off the page
  requests nothing.
- **A Linux app** (#16). WebReader now runs on Linux as a GTK4 + WebKitGTK application,
  developed against Arch/Omarchy on Hyprland. It registers as an `http`/`https` handler, so
  the browser chooser and `xdg-open` route links to it, and opens them in the same reader
  page as the Mac — same appearance settings, same recents, same suggestions. Installing it
  does not change your default browser.
- The Linux app has no menu bar; the nine host commands are `Ctrl`-based accelerators,
  chosen to stay clear of Hyprland's `Super` bindings, and they are listed on the settings
  page since there is nowhere else to read them. `webreader --clipboard` opens a URL from the
  clipboard and is worth a Hyprland binding, because it is most useful when the app is not
  focused.
- On Linux the reader's automatic theme follows the active Omarchy theme rather than a
  system light/dark switch. Explicit themes still pin their own palette.
- Reader font stacks are now chosen per platform, so Linux gets faces that actually resolve
  there (Noto Serif, Adwaita Sans) instead of falling through to Liberation.

### Changed
- Hiding boilerplate is now part of the reader itself: select a line and a **Hide text**
  button appears beside it. The Edit-menu and right-click routes are gone — one way to do it,
  and it works on a platform with no menu bar.
- Both progress hairlines read one shared thickness constant instead of two hand-kept copies.

## [0.10.1] - 2026-08-28

### Fixed
- The start page came up inert in 0.10.0: clicking a recent article did nothing and no
  suggestions ever appeared.

## [0.10.0] - 2026-08-28

### Added
- Suggested articles on the start page, ranked against what you have been reading. Ships
  with [wallnot.dk](https://wallnot.dk) — Danish articles without paywalls — as a source.
- A settings page (⌘,) for the suggestion sources: add a feed or a site address to look one
  up on, remove any of them (the shipped one included), and limit suggestions by language.
- Recents and suggestions sit side by side when the window is wide enough, and stack again
  when it is not.
- Tell the suggestions what you think: More/Less like this — on a suggested article or on the
  article you are reading — shapes what is suggested next, and blocking an outlet stops it
  being suggested at all. Blocked outlets are listed in Settings.
- Recent articles are kept on disk: opening one from the recents list is instant and works
  offline, and a failed page load falls back to the saved copy when there is one. Saved
  copies follow the recents list (30) and go with Clear history.
- Boilerplate lines such as "Artiklen fortsætter efter annoncen" and ad labels are removed
  from articles. Blocks are dropped only when their whole text matches a phrase.
- Learn new phrases as you read: select the text and pick Hide Selected Text in Articles
  from the context or Edit menu. A Hidden text popover lists them, each removable, with a
  count of what the current article lost and the phrases that hit it listed first.
- Inline quotations (»…«, “…”) are styled: a left border with the quote in medium weight,
  or italic — a new Quotes control in the Aa popover.

### Changed
- Reload (⌘R) in the reader fetches the article page again instead of redrawing the
  rendered page, refreshing the saved copy.
- The reading-progress line now uses the text color instead of the accent, so it no longer
  looks like a stalled page load.

## [0.9.0] - 2026-08-25

### Added
- WebReader is now its own project, split out of [webwrap](https://github.com/yepzdk/webwrap)
  0.8.0's reader mode. Feature parity with the webwrap-generated app: link handling with
  tracking-URL cleaning, automatic reader view, appearance controls, recents, start page,
  reading-progress line, offline page, and page zoom.
- One-time import of appearance settings, recents, and zoom from the webwrap-generated
  WebReader app on first launch.
- View → Reset Reader Appearance replaces the old Settings window's Restore Defaults.
- Release pipeline: `Scripts/release.sh` publishes a signed, notarized universal build as a
  GitHub Release and bumps the Homebrew cask `yepzdk/tools/webreader`.

### Changed
- New bundle identifier `dk.yepz.webreader`; site logins from the old app don't carry over.
- All web links now open in-window (the app is a reader for any site); non-web schemes such
  as `mailto:` still go to their owning app.

### Removed
- webwrap-only options the reader never used: navigation toolbar, Settings window, user-agent
  selector, window background color.

[Unreleased]: https://github.com/yepzdk/webreader/compare/v0.11.0...HEAD
[0.11.0]: https://github.com/yepzdk/webreader/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/yepzdk/webreader/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/yepzdk/webreader/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/yepzdk/webreader/releases/tag/v0.9.0
