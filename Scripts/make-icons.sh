#!/bin/sh
# Renders every platform's app icon from Design/AppIcon/AppIcon.svg.
#
#   Scripts/make-icons.sh
#
# Needs librsvg (`brew install librsvg`) and iconutil, which ships with Xcode. Run it after
# editing the SVG and commit what it writes; nothing builds this on the fly, because the
# Linux and Android jobs have no renderer and the App Store wants the bytes in the repo.
#
# What each platform gets, and why they are not the same picture:
#   iOS     full bleed, opaque. The system masks the corners, and an alpha channel is an
#           upload rejection (ITMS-90717).
#   macOS   inset into the rounded square Apple's icon grid asks for. Nothing masks a Mac
#           icon, so the shape has to be in the artwork or it looks like a sticker.
#   Linux   full bleed, the same bytes as iOS's largest rendition.
#   Android hand-written vector at res/drawable/ic_launcher_foreground.xml - a launcher
#           icon is a masked drawable, not a PNG, so it cannot come from here.
set -eu
cd "$(dirname "$0")/.."
SRC=Design/AppIcon/AppIcon.svg

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

# --- iOS ---------------------------------------------------------------------------------
# Every size Apple asks for, keyed by pixel dimension, so one file serves every entry that
# needs it. Contents.json is checked in and names exactly these.
SET=Sources/WebReaderiOS/Assets.xcassets/AppIcon.appiconset
for px in 20 29 40 58 60 80 87 120 152 167 180 1024; do
  rsvg-convert -w "$px" -h "$px" "$SRC" -o "$SET/AppIcon-$px.png"
done
echo "Wrote $SET"

# --- Linux -------------------------------------------------------------------------------
cp "$SET/AppIcon-1024.png" Linux/dk.yepz.webreader.png
echo "Wrote Linux/dk.yepz.webreader.png"

# --- macOS -------------------------------------------------------------------------------
# Apple's grid puts a rounded-square icon in 824 of its 1024 points, with a corner radius of
# 185.4. The artwork is scaled into that box and clipped to the shape; the margin stays
# transparent, which is what gives a Mac icon its footprint in the Dock.
#
# The wrapper inlines the source between its own tags, so AppIcon.svg has to open on its
# first line and close on its last - the comment in that file says so.
MAC=$(mktemp -d)
{
  echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
  echo '<defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185.4"/></clipPath></defs>'
  echo '<g clip-path="url(#tile)" transform="translate(100 100) scale(0.8046875)">'
  sed '1d;$d' "$SRC"
  echo '</g></svg>'
} > "$MAC/AppIcon-macOS.svg"

ICONSET="$MAC/AppIcon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" "$MAC/AppIcon-macOS.svg" -o "$MAC/$px.png"
done
for pair in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  cp "$MAC/${pair%%:*}.png" "$ICONSET/${pair#*:}.png"
done
iconutil -c icns "$ICONSET" -o App/AppIcon.icns
rm -rf "$MAC"
echo "Wrote App/AppIcon.icns"
