# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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

[Unreleased]: https://github.com/yepzdk/webreader/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/yepzdk/webreader/releases/tag/v0.9.0
