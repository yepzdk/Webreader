#!/bin/sh
# Build WebReader and install it into ~/.local for the current user only.
#
# This is the developer path on a machine that already has a Swift toolchain.
# For a system-wide install, use the PKGBUILD next to this script instead.
#
# What this script deliberately does NOT do: it never makes WebReader your
# default browser. There is no `xdg-settings set default-web-browser`, no
# `xdg-mime default`, and nothing here writes to ~/.config/mimeapps.list.
# Installing the desktop entry adds WebReader to the list of applications
# offered for http/https; choosing a default stays entirely yours, and your
# current default is left exactly as it is. The commands printed at the end
# let you verify both of those claims yourself.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

app_id="dk.yepz.webreader"
bin_dir="$HOME/.local/bin"
desktop_dir="$HOME/.local/share/applications"
icon_dir="$HOME/.local/share/icons/hicolor/1024x1024/apps"
pixmap_dir="$HOME/.local/share/pixmaps"
bin_path="$bin_dir/webreader"
desktop_path="$desktop_dir/$app_id.desktop"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' is not on PATH." >&2
    echo "       WebReader is built with SwiftPM and needs a Swift toolchain." >&2
    echo "       On Arch, install the AUR package 'swift-bin', or fetch a" >&2
    echo "       toolchain from https://www.swift.org/install/linux/" >&2
    exit 1
fi

echo "==> Building webreader (release)"
( cd "$repo_dir" && swift build -c release )

built_binary="$repo_dir/.build/release/webreader"
if [ ! -x "$built_binary" ]; then
    echo "error: build finished but '$built_binary' is missing or not executable." >&2
    exit 1
fi

echo "==> Installing to ~/.local"
install -Dm755 "$built_binary" "$bin_path"
install -Dm644 "$script_dir/$app_id.png" "$icon_dir/$app_id.png"
install -Dm644 "$script_dir/$app_id.png" "$pixmap_dir/$app_id.png"

# Rewrite Exec= to the absolute installed path. ~/.local/bin is not always on
# PATH for the desktop session (it is set up by the shell profile, which the
# session's application launcher does not necessarily source), so a bare
# "webreader" in Exec= can fail to launch from a browser or file manager.
mkdir -p "$desktop_dir"
sed "s|^Exec=webreader %u\$|Exec=$bin_path %u|" \
    "$script_dir/$app_id.desktop" >"$desktop_path"
chmod 644 "$desktop_path"

if ! grep -q "^Exec=$bin_path %u\$" "$desktop_path"; then
    echo "error: failed to rewrite Exec= in '$desktop_path'." >&2
    exit 1
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    echo "==> Updating the desktop database"
    update-desktop-database "$desktop_dir"
else
    echo "note: 'update-desktop-database' not found (package: desktop-file-utils)."
    echo "      WebReader may not appear in application lists until it is run."
fi

cat <<EOF

Installed:
  $bin_path
  $desktop_path
  $icon_dir/$app_id.png
  $pixmap_dir/$app_id.png

Your default browser was not changed. Verify for yourself:

  # WebReader should now be listed under Registered/Recommended applications.
  gio mime x-scheme-handler/https

  # Your default must be unchanged (expected here: zen.desktop).
  xdg-mime query default x-scheme-handler/https

  # Open a URL with WebReader explicitly, without touching any default.
  gio launch "$desktop_path" https://example.com

If ~/.local/bin is not on your PATH, run WebReader as $bin_path.
To uninstall, delete the four files listed above and re-run
update-desktop-database "$desktop_dir".
EOF
