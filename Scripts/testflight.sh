#!/bin/sh
# Archives the iOS/iPadOS app and uploads it to TestFlight.
#
#   Scripts/testflight.sh
#
# Needs, in this order:
#
#  1. The identifiers registered on the account. `-allowProvisioningUpdates` below creates
#     them — both bundle IDs and the app group — the first time it runs, or register them by
#     hand at developer.apple.com > Certificates, Identifiers & Profiles > Identifiers.
#  2. The app record in App Store Connect. This one cannot be automated from here: its
#     Bundle ID field is a menu of identifiers that already exist, which is why step 1 comes
#     first.
#  3. An "Apple Distribution" identity in the keychain. That is enough: with no credentials
#     set the script stops at a signed .ipa and prints how to send it from Xcode or
#     Transporter, neither of which needs a key.
#
#     For an unattended run, set one of the two pairs — an App Store Connect API key (the
#     .p8 goes in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8):
#
#       ASC_KEY_ID=ABCD123456 ASC_ISSUER_ID=<uuid> Scripts/testflight.sh
#
#     or an app-specific password from appleid.apple.com:
#
#       ASC_USERNAME=you@example.com ASC_PASSWORD=xxxx-xxxx-xxxx-xxxx Scripts/testflight.sh
#
# Nothing here touches the Mac release path in release.sh: different certificate, different
# destination, different rules.
set -eu
cd "$(dirname "$0")/.."

die() { echo "testflight: $*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------------------
# A clean tree is the default because the build number is the commit count: on a dirty tree
# it names a commit that does not contain what the testers are running, and a bug report
# against build 66 then points at the wrong code. Overridable on purpose — a beta of work in
# progress is the normal case early on — but it says so out loud, every time.
if [ -n "$(git status --porcelain)" ]; then
  [ -n "${ALLOW_DIRTY:-}" ] || die "working tree is not clean; commit first, or re-run with
ALLOW_DIRTY=1 to build it anyway"
  echo "testflight: WARNING building a dirty tree — build $(git rev-list --count HEAD) will"
  echo "testflight:         not match the commit it names. Fine for you, not for testers."
fi
security find-identity -v -p codesigning | grep -q "Apple Distribution" \
  || die "no 'Apple Distribution' identity in the keychain"

# Credentials are optional, and the archive is worth having without them: whoever is doing
# this for the first time should not have to obtain an API key before they can see whether
# the thing even builds and signs. With none set, the script stops at a finished .ipa and
# says how to send it by hand.
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  UPLOAD_WITH="key"
elif [ -n "${ASC_USERNAME:-}" ] && [ -n "${ASC_PASSWORD:-}" ]; then
  UPLOAD_WITH="password"
else
  UPLOAD_WITH="nothing"
fi

VERSION="$(xcodebuild -project WebReader.xcodeproj -target WebReaderiOS -showBuildSettings \
  2>/dev/null | sed -n 's/.*MARKETING_VERSION = \(.*\)/\1/p' | head -1)"
# The build number is the commit count: monotonic without anyone remembering to bump it, and
# it names the commit an upload came from. App Store Connect refuses a build number it has
# already seen for a version, which is exactly the mistake this avoids.
BUILD="$(git rev-list --count HEAD)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION"
echo "Uploading WebReader $VERSION ($BUILD) to TestFlight"

# --- Archive ------------------------------------------------------------------------------
# `-allowProvisioningUpdates` lets Xcode register the two bundle IDs and the app group on
# first run, and fetch the distribution profiles afterwards. It talks to Apple, so it is the
# one step that needs the account to be reachable.
#
# Archived into Xcode's own Archives folder, not into build/. The Organizer lists that folder
# and nothing else, so an archive written anywhere else is invisible there — which is how a
# rejected build got uploaded a second time while a fixed one sat on disk unseen. The name
# carries the build number for the same reason: the Organizer shows it, so the row you pick
# can be checked against what this script just said.
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/WebReader $VERSION ($BUILD).xcarchive"
mkdir -p "$(dirname "$ARCHIVE")"
rm -rf "$ARCHIVE"
xcodebuild -project WebReader.xcodeproj -scheme WebReaderiOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates archive

# --- Export -------------------------------------------------------------------------------
OPTIONS=build/ExportOptions.plist
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>96DL4CMTDZ</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
rm -rf build/ipa
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" -exportPath build/ipa \
  -allowProvisioningUpdates
IPA="$(ls build/ipa/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || die "no .ipa in build/ipa"

# --- Upload -------------------------------------------------------------------------------
# "No suitable application records were found" is the one failure that is not about this
# build at all: the app record does not exist yet in App Store Connect. The identifiers can
# be created by Xcode, but the record itself cannot — so the message says so rather than
# leaving Apple's wording to be searched for.
RECORD_HINT="if that said no suitable application records were found, the app record does
not exist yet: App Store Connect > Apps > +, and pick dk.yepz.webreader from the Bundle ID
menu. The menu only lists identifiers that are already registered — see the header."

if [ "$UPLOAD_WITH" = "nothing" ]; then
  echo
  echo "Signed $VERSION ($BUILD): $IPA"
  echo
  echo "No credentials set, so it stops here. Two ways to send it:"
  echo
  echo "  * Xcode: Window > Organizer > Archives, pick the row that reads"
  echo "    \"$VERSION ($BUILD)\" — it is the newest — then Distribute App and choose"
  echo "    App Store Connect, then Distribute. Uses the account already signed into"
  echo "    Xcode, so no key is needed."
  echo
  echo "    Not \"TestFlight Internal Only\", which is the row beside it: that flag is"
  echo "    permanent per build and bars every external group, so a build carrying it"
  echo "    shows testers outside your team no builds at all. App Store Connect covers"
  echo "    internal and external TestFlight both, and leaves the store submission"
  echo "    as a later choice rather than making one now."
  echo
  echo "  * Transporter (free, App Store): drag the .ipa in and press Deliver."
  echo
  echo "For an unattended run, set either ASC_KEY_ID + ASC_ISSUER_ID (an App Store Connect"
  echo "API key) or ASC_USERNAME + ASC_PASSWORD (an app-specific password)."
  exit 0
fi

# Validated before uploading: altool reports the same rejections either way, and a failed
# validation costs seconds where a failed upload costs the processing wait.
if [ "$UPLOAD_WITH" = "key" ]; then
  set -- --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
else
  set -- --username "$ASC_USERNAME" --password "$ASC_PASSWORD"
fi
xcrun altool --validate-app -f "$IPA" -t ios "$@" || die "$RECORD_HINT"
xcrun altool --upload-app -f "$IPA" -t ios "$@" || die "$RECORD_HINT"

echo
echo "Uploaded $VERSION ($BUILD). App Store Connect takes a few minutes to process it;"
echo "TestFlight will email your internal testers as soon as it does."
