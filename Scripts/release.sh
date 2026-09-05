#!/bin/sh
# Publishes the version in App/Info.plist as a signed, notarized, universal GitHub Release
# and bumps the Homebrew cask. Run on a clean main after the release PR has merged:
#
#   git checkout main && git pull && Scripts/release.sh
#
# Needs: a "Developer ID Application" identity in the keychain (auto-detected, or set
# SIGN_IDENTITY), a notarytool keychain profile (default "webreader"; set NOTARY_PROFILE),
# and a logged-in `gh`. The release itself is published before the cask is bumped, so if the
# tap push fails the script prints the one-line retry.
set -eu
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------------------
[ "$(git branch --show-current)" = "main" ] || die "run on main (you're on '$(git branch --show-current)')"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
VERSION="$(plutil -extract CFBundleShortVersionString raw App/Info.plist)"
grep -q "^## \[$VERSION\]" CHANGELOG.md \
  || die "CHANGELOG.md has no '## [$VERSION]' section — roll [Unreleased] first"
git fetch -q --tags
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$SIGN_IDENTITY" ] || die "no 'Developer ID Application' identity in the keychain"
NOTARY_PROFILE="${NOTARY_PROFILE:-webreader}"
echo "Releasing WebReader $VERSION, signing as '$SIGN_IDENTITY'"

# --- Build: universal, Developer ID, hardened runtime -------------------------------------
# CONFIG is pinned, not inherited: build-app.sh defaults to release but honours the
# environment, and an exported CONFIG=debug would sail through lipo, codesign --verify and
# notarytool to publish an `isInspectable` bundle.
CONFIG=release ARCHS="--arch arm64 --arch x86_64" SIGN_IDENTITY="$SIGN_IDENTITY" \
  Scripts/build-app.sh
APP=build/WebReader.app
ARCHES="$(lipo -archs "$APP/Contents/MacOS/WebReader")"
case "$ARCHES" in *arm64*x86_64*|*x86_64*arm64*) ;; *) die "binary is not universal: $ARCHES" ;; esac
codesign --verify --strict --deep "$APP"

# --- Notarize and staple ------------------------------------------------------------------
ditto -c -k --keepParent "$APP" build/notarize.zip
# --wait exits 0 even when Apple rejects the submission; the status line is the verdict.
xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait \
  | tee build/notarize.log
grep -q "status: Accepted" build/notarize.log \
  || die "notarization not accepted — see 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE'"
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"

# --- Package -----------------------------------------------------------------------------
ZIP="build/WebReader-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256" build/WebReader.zip build/notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" build/WebReader.zip
(cd build && shasum -a 256 "WebReader-$VERSION.zip" > "WebReader-$VERSION.zip.sha256")
SHA="$(cut -d' ' -f1 "$ZIP.sha256")"

# --- Android APK (optional) ---------------------------------------------------------------
# Opt-in, because it needs two things a Mac has no reason to carry: the Swift SDK for Android
# and a signing keystore. Absent either, the release is the Mac's alone and says so — a
# release that failed because a phone toolchain was missing would be a worse trade.
#
# Set ANDROID_KEYSTORE to a keystore path to include them, and ANDROID_BUILD_TOOLS if the
# build-tools are not the newest under ANDROID_HOME.
#
# A plain string rather than an array, because this script is `#!/bin/sh`: the paths are
# generated here, so word splitting on them is safe, and it is why `$APKS` goes unquoted at
# the `gh release create` below.
APKS=""
if [ -n "${ANDROID_KEYSTORE:-}" ] && [ -f "${ANDROID_KEYSTORE}" ]; then
  SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  if [ -z "${ANDROID_BUILD_TOOLS:-}" ]; then
    # Newest by version sort, which is what `ls` gives in the layout the SDK manager writes.
    ANDROID_BUILD_TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
  fi
  [ -x "$ANDROID_BUILD_TOOLS/apksigner" ] \
    || die "no apksigner at $ANDROID_BUILD_TOOLS; set ANDROID_BUILD_TOOLS"
  echo "Building the Android APKs…"
  ABIS="aarch64-unknown-linux-android28 x86_64-unknown-linux-android28" Scripts/build-android.sh
  (cd android && ./gradlew --quiet :app:assembleRelease)
  for abi in arm64-v8a x86_64; do
    unsigned="android/app/build/outputs/apk/release/app-$abi-release-unsigned.apk"
    [ -f "$unsigned" ] || die "expected $unsigned"
    signed="build/WebReader-$VERSION-$abi.apk"
    # zipalign before apksigner: the aligner cannot fix a signed archive, and an unaligned
    # APK is rejected on install.
    "$ANDROID_BUILD_TOOLS/zipalign" -f -p 4 "$unsigned" "$signed.aligned"
    "$ANDROID_BUILD_TOOLS/apksigner" sign --ks "$ANDROID_KEYSTORE" \
      --out "$signed" "$signed.aligned"
    rm -f "$signed.aligned"
    "$ANDROID_BUILD_TOOLS/apksigner" verify "$signed" || die "apksigner rejected $signed"
    APKS="$APKS $signed"
  done
else
  echo "Skipping the Android APKs: set ANDROID_KEYSTORE to include them."
fi

# --- Publish -----------------------------------------------------------------------------
# Release notes: this version's CHANGELOG section, minus its heading.
awk -v v="$VERSION" '/^## \[/{p=($0 ~ "^## \\[" v "\\]")} p' CHANGELOG.md | tail -n +2 > build/notes.md
gh release create "v$VERSION" build/WebReader.zip "$ZIP" "$ZIP.sha256" $APKS \
  --title "WebReader $VERSION" --notes-file build/notes.md
echo "Released: https://github.com/yepzdk/webreader/releases/tag/v$VERSION"
echo "Stable download: https://github.com/yepzdk/webreader/releases/latest/download/WebReader.zip"

# --- Homebrew cask -----------------------------------------------------------------------
Scripts/update-cask.sh "$VERSION" "$SHA" \
  || die "cask bump failed; the release is published. Retry: Scripts/update-cask.sh $VERSION $SHA"
echo "Install: brew install --cask yepzdk/tools/webreader"
