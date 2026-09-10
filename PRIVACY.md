# Privacy

**WebReader collects nothing.** No account, no analytics, no tracking, no advertising,
no third-party SDKs of any kind. Nothing about you or what you read is sent to the
developer, because there is nowhere for it to be sent.

Last updated: 10 September 2026.

## What stays on your device

- The addresses of articles you have opened, newest first, capped at the thirty most
  recent.
- Your reading settings: theme, type size, column width, line height, quote style,
  thumbnails, which side the controls sit on, and which list the start page leads with.
- The feeds you have added as suggestion sources, the outlets you have blocked, and the
  "more like this" / "fewer like this" opinions you have given.
- A small cache of recently read articles, so an article you have already read opens
  without asking the site for it again.

All of it lives in the app's own storage. Deleting the app deletes it. "Clear history"
in the app removes the reading history on demand.

## What leaves your device

**The pages and feeds you ask for.** When you open an article, the app requests it from
that site directly, exactly as a browser would. When you add a feed, the app fetches that
feed periodically while the app is open. Those servers see what any web request shows
them — your IP address, the address requested, and the app's user agent. The app sends
them nothing else: no identifier, no history, no list of your other sources.

Article text is turned into the reader's own page **on your device**. Page content is
never uploaded anywhere.

**Sync, only if you turn it on.** Sync is off by default. When you enable it, the app
writes one small file describing your settings and recent articles to a location you
choose — a folder on your device, a Nextcloud or other WebDAV server you supply, or a
folder kept in sync by something else you already run. That destination is yours. The
developer has no server, receives no copy, and cannot read it.

## What Apple and Google see

While the app is distributed through TestFlight or Google Play, those platforms collect
installation and crash information under their own terms, as they do for every app on
their stores. That data goes to Apple or Google, not to the developer beyond the
anonymous crash reports and counts their consoles display. Nothing in the app reports to
them beyond what the platform itself does.

## Children

The app has no accounts, no messaging, no user-generated content and no advertising. It
collects nothing from anyone, of any age.

## Changes

If this ever stops being accurate, this file changes with it, and its history is public
in the repository alongside the code that it describes.

## Contact

jesper@yepz.dk
