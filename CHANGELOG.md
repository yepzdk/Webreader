# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.14.0] - 2026-09-11

### Added
- **Choose how loud a link is, not just what colour** (#45). Four levels: follow the text
  and let the underline mark it, or a bright, tinted or hushed shade of your chosen hue.
  Hushed is the new default — the old saturated links read as noise on a page whose point
  is not having any. Every shade still clears 4.5:1 on every theme.
- **The start page has its own appearance popover** with its own text size and typeface,
  plus which of its two lists leads and whether rows carry thumbnails. Its lists were
  pinned smaller than anything you could choose; sharing the reader's settings was worse,
  since a 22px serif article dragged them along with it.
- **The reader's popover gained the controls that belong to it**: quotes, thumbnails and
  which edge its buttons sit against.
- **Every row in both popovers says what it does.** Controls a screen reader could name
  and a sighted reader had to guess at.

### Changed
- **The app has an icon of its own.** A brass drop cap opening a paragraph, with a page
  marker beside it, replacing the placeholder W on slate. Every platform renders from one
  SVG through `Scripts/make-icons.sh`, so the Mac, iPhone, iPad, Android and Linux icons
  cannot drift apart.
- **The way back to the site is a globe.** It used to be the arrow leaving a box, which on
  the web means "this opens somewhere else" — the page arrives in the same window.
- **Every button the accent touches is an outline now.** A filled one reads fine until the
  accent is the page's own text colour — on black, "Open" was a white label on a
  near-white fill. The colour goes on the background it was measured against instead, and
  a control that is "on" fills its icon.
- **Settings no longer holds article images, start page order or the reader's control
  edge.** All three now live in the popover of the surface they change, where the effect is
  on screen while you choose.

### Fixed
- **An article's first line no longer reads grey.** The fade behind the top controls was
  sized for a finger on every device, so on a desktop it painted 34px past where the
  article began. Both the fade and the headroom now follow the controls that are actually
  up there.
- **The Mac icon sits in the Dock at the size every other app does.** Its rounded tile was
  being scaled twice, which cropped the artwork and left it small and soft beside its
  neighbours.
- **The "show the original page" button looks like the buttons beside it**, and hides with
  them when the controls collapse on a phone. It was in no style rule and no id list, so
  the engine drew its own default button and left it on screen alone.
- **The start page no longer offers to show "the original page".** There is no article
  there and no site to go back to; the button did nothing when pressed.

## [0.13.0] - 2026-09-11

### Added
- **Turn the reader off for a site, so you can log in** (#44). A paywall's sign-in form is
  the site's own page, and an extracted copy has no form in it. The reader's menu hands the
  site back and stays out of the way on that host; our own way back is injected over it, so
  the decision is reversible from where it was made. Travels between devices with the rest
  of the settings.
- **Pick the colour links take** (#45). Five vetted accents, each with its own shade per
  theme — the blue that reads on cream is not the one that reads on black. Sepia's default
  blue measured 4.39:1 against its background, under the 4.5:1 a link needs, and now
  clears it.

### Fixed
- **A site could turn the reader off for itself.** On Android the page bridge is reachable
  from any document, so a publisher could have disabled the reader for its own domain —
  durably, and on every device the settings reach. That decision now has to come from the
  app's own chrome, and a page can only ever decide about its own host.

## [0.12.0] - 2026-09-10

### Added
- Sync appearance settings and recents between devices through a folder you pick — your
  Nextcloud folder, iCloud Drive, anything that already syncs. Set it up in Settings (⌘,);
  page zoom stays local, and the Linux app has no folder picker yet.
- **WebReader on iPhone and iPad** (#6). Share a link from Safari or anywhere else and it
  opens in the same reader page as the Mac, with the same appearance settings, the same
  recents, and sync to a folder you pick. Built from the same reader code as the Mac app,
  not a second copy of it.
- **WebReader on Android** (#9). Open a link from any app or share one to WebReader and it
  lands in the same reader page as everywhere else, with the same appearance settings and
  recents, synced through a folder you pick. The reader logic is the same compiled code as
  the Mac's — ReaderKit runs natively on Android — so the two cannot drift apart. Adding a
  suggestion source needs the feed's own address there for now; a bare site address finds
  nothing.
- **Choose what the start page leads with.** Settings now has a Start page section: recent
  articles first, as before, or suggested articles first.
- **A feed address offers to become a source** (#43). Open one and the page says what it is
  and offers to add it to suggested articles, rather than only telling you there is nothing
  to read.
- **On a tablet the reader's controls sit in the middle of an edge**, behind one button, in
  reach of the hand holding it — the two top corners are the hardest places to reach on a
  screen you are holding. Settings picks the edge: right, or left.
- **An article ends with three things to read next.** Finishing one meant going back to the
  start page to find another; the same ranked suggestions the reader's popover already
  carried now sit at the end of the article too, and open on a tap.

### Changed
- The reader itself moves into `ReaderSession` (#6, #9): what the app decides — which page is
  on screen, when an article is extracted, what each control does — is now one implementation
  that every platform drives, and each host only carries the code that talks to its own web
  view. No change to how the Mac app behaves.
- **A shared link can carry a headline** (#9). Sharing "Worth reading: https://…" now opens
  the link instead of refusing it. Pasting prose into the URL field is still refused: a paste
  of a sentence is more likely a mistake than an invitation to guess.
- **Recents live on the start page** (#32). The reader's recents popover duplicated the
  inline list and the hidden-text panel had no article to group against, so both leave the
  reader; hidden phrases move to the settings page, beside blocked outlets.
- **Five recent, five suggested** (#33). The reader's recents popover lists five recent
  articles instead of the whole history, followed by five suggestions — both with
  thumbnails — so you can pick up something new without going home first.
- **Article images move to settings.** The Aa popover's Images switch read as governing the
  article's own images, which it never did; it becomes an **Article images** section with one
  switch per surface. Anyone who had the old switch off gets both new ones off.
- Recents now record when an article was read, and clearing history leaves a timestamp, so
  two devices merge in the right order and a clear isn't undone by a device that was off.
  Existing lists are read as before, on both platforms.
- **The pages work on a touch screen** (#36). Controls reach a 44px target, popovers stay on
  screen and clear the safe areas, and the layout stops spending desktop gutters and 18vh of
  headroom on a phone. A roomy desktop window renders exactly as before.
- **The reader's controls collapse behind one button wherever a hand does the reaching**
  (#36). Six buttons over an article compete with it, and the corners are hard to reach
  one-handed; one button now opens them as a column. Any touch screen triggers it, and so
  does a narrow desktop window.
- **The compact chrome says what its controls are.** The button that opens them takes the
  three-line mark and is a little larger — the vertical ellipsis now belongs to a suggested
  row's own menu — and every control carries its name beside its icon, "Aa" included. A
  roomy window keeps the icons alone, where hovering one already names it.
- **A suggested row's controls live behind one button.** More, Less, Block and Hide sat
  beside every headline, which read as clutter and spent width the headline wanted; tapping
  the row's own menu now swaps them in, one row at a time, at every window size. Blocking an
  outlet has its own mark, and the X beside it closes the menu rather than banning the
  source.

### Fixed
- **The article you had just read was offered again at the end of it.** A feed's address for
  a story and the address the site redirects you to are not the same string —
  `dr.dk/…` against `www.dr.dk/…` — so "already read" never matched and every article
  suggested itself, with the rest of the list barely changing. The same story carried by two
  feeds under two spellings also collapses into one row now.
- **A feed address left the app with no way out.** Opening one — pasting it into Open URL from
  Clipboard, say — showed either nothing at all or a page made of angle brackets, with none of
  the reader's own chrome on it. It now says there is nothing to read there and offers Home.
- **On Android a load that never landed never ended.** A site that answered and then went
  silent left the app waiting behind a bare screen with the progress line sweeping, with
  nothing to do but quit it. Such a load is now given up on after 20 seconds and reported as
  the timeout it is, with Try Again. (WebKit raises its own timeout, so the Mac already had
  an ending.)
- **A glimpse of the site showed before the reader replaced it.** The cover came down as the
  reader document was handed over rather than when it appeared, so the page it was about to
  replace got a frame or two on screen.
- **Back from an article returned to the same article** (#42). The web view's history holds
  the page each article was extracted from, so going back through one extracted it again and
  landed you where you started. Back now walks the reader's own places — the previous
  article, or the page it came from — and from the start page it leaves the app.
- **The reader's width setting did nothing on a narrow screen.** Below 48rem — a phone, or a
  narrow window on a Mac — all three widths are wider than the viewport, so they looked
  identical; the setting now picks the gutter instead. The default reads exactly as before.
- **Buttons stayed on screen after collapsing the reader controls** (#36). Collapsing hid them
  but left their boxes standing, so parts of the column kept being drawn until the next window
  resize. The 140ms fade goes with the fix.
- **Suggested-article controls were unreachable without a mouse** (#36). More, Less and Block
  on a suggested row were revealed on hover, so they were invisible and unusable on any touch
  screen; they are visible by default now.
- **Article text ran through the top buttons while scrolling.** The gaps between the buttons
  let the article through, leaving a line of text crossing the icons with neither readable. A
  gradient that follows the theme now sits behind them.
- **Page text sat under the notch** (#36). The floating controls cleared the safe area from
  the start, but the pages' own content did not, so on an iPhone the start page's title ran
  behind the Dynamic Island. Only ever visible on hardware with an inset.
- **On a tablet the article's first line started inside the top controls** (#36). Touch grew
  the buttons to a 44px target without growing the headroom above the text to match, which a
  mouse never showed because its buttons are smaller.

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

[Unreleased]: https://github.com/yepzdk/webreader/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/yepzdk/webreader/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/yepzdk/webreader/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/yepzdk/webreader/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/yepzdk/webreader/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/yepzdk/webreader/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/yepzdk/webreader/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/yepzdk/webreader/releases/tag/v0.9.0
