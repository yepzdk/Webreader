# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
- Sync appearance settings and recents between devices through a folder you pick — inside
  your Nextcloud folder, iCloud Drive, or anything else that syncs. Each device writes its
  own file, so nothing collides and no device can wipe another's list. Turn it on under
  Sync… in the WebReader menu; page zoom stays local. Mac only for now.

### Changed
- Hiding boilerplate is now part of the reader itself: select a line and a **Hide text**
  button appears beside it. The Edit-menu and right-click routes are gone — one way to do it,
  and it works on a platform with no menu bar.
- Both progress hairlines read one shared thickness constant instead of two hand-kept copies.
- Recents now record when an article was read, and clearing history leaves a timestamp, so
  two devices merge in the right order and a clear isn't undone by a device that was off.
  Existing lists are read as before.

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

[Unreleased]: https://github.com/yepzdk/webreader/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/yepzdk/webreader/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/yepzdk/webreader/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/yepzdk/webreader/releases/tag/v0.9.0
