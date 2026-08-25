#!/bin/sh
# Writes Casks/webreader.rb in the yepzdk/homebrew-tools tap for a published release and
# pushes it. Called by release.sh; safe to re-run by hand if that step failed:
#
#   Scripts/update-cask.sh 0.9.0 <sha256 of WebReader-0.9.0.zip>
#
# The whole file is rewritten from the template below (not sed-patched), so the first release
# creates the cask and later ones can't drift from it.
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 <version> <sha256>" >&2; exit 2; }
VERSION="$1"
SHA="$2"

TAP=build/tap
rm -rf "$TAP"
gh repo clone yepzdk/homebrew-tools "$TAP" -- --depth 1 --quiet
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/webreader.rb" <<EOF
cask "webreader" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/yepzdk/webreader/releases/download/v#{version}/WebReader-#{version}.zip"
  name "WebReader"
  desc "Distraction-free reading app: send it a link, read the article"
  homepage "https://github.com/yepzdk/webreader"

  depends_on macos: :ventura

  app "WebReader.app"

  zap trash: [
    "~/Library/HTTPStorages/dk.yepz.webreader",
    "~/Library/Preferences/dk.yepz.webreader.plist",
    "~/Library/Saved Application State/dk.yepz.webreader.savedState",
    "~/Library/WebKit/dk.yepz.webreader",
  ]
end
EOF
brew style "$TAP/Casks/webreader.rb"

git -C "$TAP" add Casks/webreader.rb
if git -C "$TAP" diff --cached --quiet; then
  echo "Cask already at $VERSION; nothing to push."
  exit 0
fi
git -C "$TAP" commit -q -m "Update webreader cask to $VERSION"
git -C "$TAP" push -q
echo "Cask pushed: brew install --cask yepzdk/tools/webreader  ($VERSION)"
