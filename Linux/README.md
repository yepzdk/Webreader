# Linux packaging

Everything needed to install the GTK4 / WebKitGTK host on Linux. The macOS
scripts in `Scripts/` (`build-app.sh`, `release.sh`) are a separate path and
are not used here.

| File | Purpose |
| --- | --- |
| `dk.yepz.webreader.desktop` | Desktop entry. Registers WebReader as an `http`/`https` handler so it appears in `xdg-settings`, `gio mime`, and the browsers' default-application lists. |
| `dk.yepz.webreader.png` | Application icon, 1024x1024. |
| `PKGBUILD-git` | Arch **VCS** package `webreader-git`, built from the default branch. **This is the one that works today** — see below. |
| `PKGBUILD` | Arch release package `webreader`, built from the `v0.12.0` tag. |
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

There are two PKGBUILDs, because the two AUR packages they correspond to are
separate AUR repositories and `makepkg` only ever reads a file named exactly
`PKGBUILD`. Keeping them as two plain files means each can be copied to its AUR
repo verbatim, with no editing and no parameter to get wrong.

| File | AUR package | Source | Usable now? |
| --- | --- | --- | --- |
| `PKGBUILD-git` | `webreader-git` | default branch, no tag | **yes** |
| `PKGBUILD` | `webreader` | `v0.12.0` tag | yes |

### Use `PKGBUILD-git` today

The GTK4 / WebKitGTK host landed *after* `v0.10.1`, so no tag in the repository
contains it — `git ls-tree -r --name-only v0.10.1 | grep WebReaderGTK` matches
nothing. A release PKGBUILD pinned to any existing tag would clone a tree with
no Linux host and fail with no binary to install. The VCS package is the
standard AUR answer to that, and it is the variant that actually builds:

```sh
mkdir -p /tmp/webreader-git
install -Dm644 Linux/PKGBUILD-git /tmp/webreader-git/PKGBUILD
cd /tmp/webreader-git && makepkg
```

Verified on Arch with `swift-bin` 6.3.3, `gtk4` and `webkitgtk-6.0` installed.
It clones the default branch, computes `pkgver` from `git describe`, runs
`swift build -c release --disable-sandbox`, and produces
`webreader-git-0.10.1.r4.ga07ef2b-1-x86_64.pkg.tar.zst` (plus a `-debug`
package, because Arch's default `makepkg.conf` enables `debug`). Install it with
`makepkg -si` instead, or `pacman -U` the resulting file.

`pkgver` is generated, not hand-written: `0.10.1.r4.ga07ef2b` is the Arch VCS
convention of *last tag . commits since . short sha*, so the package version
rises monotonically with every commit and `pacman` sees upgrades correctly. The
package sets `provides=('webreader')` and `conflicts=('webreader')` so it and
the release package are interchangeable and cannot be co-installed.

### `PKGBUILD` waits on a `v0.11.0` tag

The release PKGBUILD names `pkgver=0.11.0` — the first release that *will*
contain the Linux host — rather than a version whose tag demonstrably lacks it.
No tag has been fabricated and no checksum invented, so it fails fast and
honestly today:

```
fatal: invalid reference: v0.11.0
==> ERROR: Failure while creating working copy of webreader git repo
```

It needs no further changes; tagging and pushing `v0.11.0` is the only thing
standing between it and a working `makepkg -si`.

### Both variants

Runtime dependencies are `gtk4` and `webkitgtk-6.0`, both in the official
`extra` repository — nothing from the AUR is needed to *run* WebReader.

The build dependency is the awkward part and worth stating plainly: WebReader
is written in Swift, and Arch ships no Swift toolchain in the official
repositories, so `makedepends` includes `swift-bin` — an **AUR** package. That
means building from source needs AUR access and about a gigabyte of toolchain
that is useless once the build is done. The fix for users is a companion
`webreader-bin` package shipping a prebuilt binary from a GitHub release, with
no makedepends at all; it is named as the intended option at the top of both
PKGBUILDs but has not been written — and it needs a GitHub release to exist
first, which is the same `v0.11.0` tag the release PKGBUILD is waiting on.

Either package installs the same payload, confirmed against the built
`.pkg.tar.zst` with `bsdtar -tf`:

```
usr/bin/webreader
usr/share/applications/dk.yepz.webreader.desktop
usr/share/icons/hicolor/1024x1024/apps/dk.yepz.webreader.png
usr/share/licenses/webreader-git/LICENSE
usr/share/licenses/webreader-git/LICENSE.readability
usr/share/pixmaps/dk.yepz.webreader.png
```

`LICENSE` is MIT, for WebReader itself; `LICENSE.readability` is Apache-2.0, for
the Mozilla Readability code vendored into
`Sources/ReaderKit/ReadabilityJS.swift` and compiled into the shipped binary.
The licences directory is named after the package, so it is
`/usr/share/licenses/webreader/` for the release variant. The packaged binary is
a stripped x86_64 PIE ELF linked against `libwebkitgtk-6.0.so.4`,
`libjavascriptcoregtk-6.0.so.1` and `libgtk-4.so.1`, with no unresolved
libraries.

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

`StartupWMClass=dk.yepz.webreader` matches the toplevel's WM class. GTK4 uses the
GApplication id as the Wayland app_id, not the executable name, so the class is the
reverse-DNS id even though the command is `webreader` — confirmed with `hyprctl clients`.
Window rules target it directly:

```
windowrulev2 = float, class:^(dk\.yepz\.webreader)$
```

The host's accelerators are all `Ctrl`-based, so none of them collide with
Hyprland's `Super` bindings.
