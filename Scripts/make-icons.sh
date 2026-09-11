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
# Nothing masks a Mac icon, so the shape and its footprint are the artwork's job. The numbers
# are measured off this machine's own system icons rather than taken from a document: Notes,
# Mail and Safari all draw a 204px shape in a 256px canvas (79.7%, so 824 of 1024) whose
# corner fits a 44px circular radius to within a pixel - 21.6% of the side, hence 178 - and
# they sit dead centre, with a soft shadow that reaches about 10px past the shape.
#
# The clip is a separate group *outside* the transform on purpose. `clip-path` resolves in
# the coordinate system the element's own transform establishes, so a clip and a scale on one
# group scales the clip too: the first version of this shipped a tile of 664px - 0.8047
# squared - which cropped the artwork and left it small and soft beside every other icon.
#
# The wrapper inlines the source between its own tags, so AppIcon.svg has to open on its
# first line and close on its last - the comment in that file says so.
MAC=$(mktemp -d)
{
  echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
  echo '<defs>'
  echo '<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="178"/></clipPath>'
  echo '<filter id="shade" x="-10%" y="-10%" width="120%" height="120%">'
  echo '<feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#000" flood-opacity="0.32"/>'
  echo '</filter>'
  echo '</defs>'
  echo '<g filter="url(#shade)"><g clip-path="url(#tile)">'
  echo '<g transform="translate(100 100) scale(0.8046875)">'
  sed '1d;$d' "$SRC"
  echo '</g></g></g></svg>'
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
