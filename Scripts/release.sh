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
ARCHS="--arch arm64 --arch x86_64" SIGN_IDENTITY="$SIGN_IDENTITY" Scripts/build-app.sh
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

# --- Publish -----------------------------------------------------------------------------
# Release notes: this version's CHANGELOG section, minus its heading.
awk -v v="$VERSION" '/^## \[/{p=($0 ~ "^## \\[" v "\\]")} p' CHANGELOG.md | tail -n +2 > build/notes.md
gh release create "v$VERSION" build/WebReader.zip "$ZIP" "$ZIP.sha256" \
  --title "WebReader $VERSION" --notes-file build/notes.md
echo "Released: https://github.com/yepzdk/webreader/releases/tag/v$VERSION"
echo "Stable download: https://github.com/yepzdk/webreader/releases/latest/download/WebReader.zip"

# --- Homebrew cask -----------------------------------------------------------------------
Scripts/update-cask.sh "$VERSION" "$SHA" \
  || die "cask bump failed; the release is published. Retry: Scripts/update-cask.sh $VERSION $SHA"
echo "Install: brew install --cask yepzdk/tools/webreader"
