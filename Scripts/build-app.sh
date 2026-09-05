#!/bin/sh
# Builds build/WebReader.app from the SwiftPM build.
#
#   Scripts/build-app.sh            # ad-hoc signed release bundle in build/
#   Scripts/build-app.sh --install  # …and replace /Applications/WebReader.app
#   CONFIG=debug Scripts/build-app.sh   # inspectable bundle, for Safari's Develop menu
#
# CONFIG defaults to release. A debug bundle is the only one that can be inspected: the
# web view opts into `isInspectable` under `#if DEBUG`, and every page in this app is a
# generated Swift string, so "is this rule applying?" otherwise has no answer short of
# rebuilding with a guess in it.
#
# SIGN_IDENTITY="Developer ID Application: …" signs with the hardened runtime instead of
# ad-hoc. ARCHS="--arch arm64 --arch x86_64" builds a universal binary (CI release).
set -eu
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"

# shellcheck disable=SC2086  # ARCHS is deliberately word-split into flags
swift build -c "$CONFIG" ${ARCHS:-}
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" ${ARCHS:-} --show-bin-path)/WebReader"

APP="build/WebReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WebReader"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/WebReader.app
  cp -R "$APP" /Applications/WebReader.app
  echo "Installed /Applications/WebReader.app"
fi
