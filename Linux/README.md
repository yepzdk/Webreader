# Linux packaging

Everything needed to install the GTK4 / WebKitGTK host on Linux. The macOS
scripts in `Scripts/` (`build-app.sh`, `release.sh`) are a separate path and
are not used here.

| File | Purpose |
| --- | --- |
| `dk.yepz.webreader.desktop` | Desktop entry. Registers WebReader as an `http`/`https` handler so it appears in `xdg-settings`, `gio mime`, and the browsers' default-application lists. |
| `dk.yepz.webreader.png` | Application icon, 1024x1024. |
| `PKGBUILD` | Arch source package (`makepkg -si`), suitable for the AUR. |
| `install-local.sh` | Build and install into `~/.local` for the current user, no root needed. |

## Local install

```sh
cd Linux
./install-local.sh
```

Requires a Swift toolchain on `PATH` (`swift-bin` from the AUR, or a
toolchain from swift.org) plus `gtk4` and `webkitgtk-6.0`. The script builds
`swift build -c release`, then installs:

- the binary to `~/.local/bin/webreader`
- the desktop entry to `~/.local/share/applications/`, with `Exec=` rewritten
  to the absolute `~/.local/bin/webreader` path, because `~/.local/bin` is not
  reliably on the desktop session's `PATH`
- the icon to `~/.local/share/icons/hicolor/1024x1024/apps/` and
  `~/.local/share/pixmaps/`

and finally refreshes the desktop database. It prints the verification
commands when it finishes. Uninstalling is deleting those four files.

## Arch package

```sh
cd Linux
makepkg -si
```

`pkgname=webreader`, built from the `v0.10.1` git tag. Runtime dependencies are
`gtk4` and `webkitgtk-6.0`, both in the official `extra` repository.

The build dependency is the awkward part and worth stating plainly: WebReader
is written in Swift, and Arch ships no Swift toolchain in the official
repositories, so `makedepends` includes `swift-bin` — an **AUR** package. That
means building from source needs AUR access and about a gigabyte of toolchain
that is useless once the build is done. The fix for users is a companion
`webreader-bin` package shipping a prebuilt binary from a GitHub release, with
no makedepends at all; it is named as the intended option at the top of the
`PKGBUILD` but has not been written.

The package installs the binary to `/usr/bin/webreader`, the desktop entry to
`/usr/share/applications/`, the icon to both hicolor and `/usr/share/pixmaps/`,
and two licence files to `/usr/share/licenses/webreader/`: `LICENSE` (MIT, for
WebReader itself) and `LICENSE.readability` (Apache-2.0, for the Mozilla
Readability code vendored into `Sources/ReaderKit/ReadabilityJS.swift` and
compiled into the shipped binary).

## Icon provenance

`dk.yepz.webreader.png` is **1024x1024**, 8-bit RGBA, non-interlaced. The repo
contains no PNG or SVG artwork — the only asset is `App/AppIcon.icns`, a macOS
icon container that stores its representations as back-to-back PNGs. This file
is the largest of the eight PNGs embedded in that container, extracted
byte-for-byte by scanning for the PNG signature and walking the chunk table to
`IEND`; it is not re-encoded or rescaled.

It is installed to `hicolor/1024x1024/apps/` *and* to `pixmaps/`. The second
copy is not redundant: hicolor's `index.theme` on Arch enumerates sizes only up
to 512x512, so a 1024x1024 directory is outside the theme index and is not
guaranteed to be searched, whereas `pixmaps` is the unthemed fallback directory
that the Icon Theme Specification always searches. Should a properly scaled
512x512 asset ever land in the repo, the hicolor path should move to
`512x512/apps/` and the `pixmaps` copy can be dropped.

## This does not change your default browser

Neither the package nor `install-local.sh` runs `xdg-settings set`, runs
`xdg-mime default`, or writes to `mimeapps.list`. The `MimeType=` line in the
desktop entry only *declares* that WebReader can open `text/html` and
`http`/`https` URLs, which is what puts it in the chooser lists; defaults are
recorded separately, per user, in `~/.config/mimeapps.list`. Installing
WebReader adds an option and takes none away.

After installing you can confirm this:

```sh
gio mime x-scheme-handler/https          # WebReader listed as registered/recommended
xdg-mime query default x-scheme-handler/https   # your existing default, unchanged
```

To open a URL in WebReader without making it the default:

```sh
gio launch ~/.local/share/applications/dk.yepz.webreader.desktop https://example.com
```

Or set it as your default deliberately, if that is what you want:

```sh
xdg-settings set default-web-browser dk.yepz.webreader.desktop
```

## Hyprland

`StartupWMClass=webreader` matches the toplevel's WM class, so window rules can
target it directly:

```
windowrulev2 = float, class:^(webreader)$
```

The host's accelerators are all `Ctrl`-based, so none of them collide with
Hyprland's `Super` bindings.
