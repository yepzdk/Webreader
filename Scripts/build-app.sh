#!/bin/sh
# Builds build/WebReader.app from the SwiftPM release build.
#
#   Scripts/build-app.sh            # ad-hoc signed bundle in build/
#   Scripts/build-app.sh --install  # …and replace /Applications/WebReader.app
#
# SIGN_IDENTITY="Developer ID Application: …" signs with the hardened runtime instead of
# ad-hoc. ARCHS="--arch arm64 --arch x86_64" builds a universal binary (CI release).
set -eu
cd "$(dirname "$0")/.."

# shellcheck disable=SC2086  # ARCHS is deliberately word-split into flags
swift build -c release ${ARCHS:-}
# shellcheck disable=SC2086
BIN="$(swift build -c release ${ARCHS:-} --show-bin-path)/WebReader"

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
