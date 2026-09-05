#!/bin/bash
# Cross-compiles ReaderKit and the JNI shim into the jniLibs the Gradle module packages.
#
#   Scripts/build-android.sh                                  # arm64-v8a, for real devices
#   ABIS="aarch64-unknown-linux-android28 x86_64-unknown-linux-android28" Scripts/build-android.sh
#
# ABIS is a space-separated list of Swift target triples, not Android ABI names; add the
# x86_64 one when you need the emulator, which is x86_64 even on an Apple Silicon Mac.
# CONFIG defaults to release.
#
# TOOLCHAIN must be the *open-source* Swift toolchain: Xcode's has no Android target and
# cannot cross-compile at all, so it is put ahead of /usr/bin/swift on PATH rather than
# alongside it. SDK is the Swift SDK name as `swift sdk list` prints it.
#
# Everything the script emits under android/app/src/main/jniLibs/ is generated: the .so
# built here plus the Swift runtime the app has to carry, since Android ships none of it.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLCHAIN="${TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain}"
SDK="${SDK:-swift-6.3.3-RELEASE_android}"
CONFIG="${CONFIG:-release}"
ABIS="${ABIS:-aarch64-unknown-linux-android28}"

if [ -x "$TOOLCHAIN/usr/bin/swift" ]; then
  export PATH="$TOOLCHAIN/usr/bin:$PATH"
elif [ "$(uname -s)" = "Darwin" ]; then
  echo "build-android.sh: no Swift toolchain at $TOOLCHAIN" >&2
  echo "  Xcode's toolchain cannot cross-compile. Install the swift.org macOS toolchain" >&2
  echo "  package from https://www.swift.org/install/macos/, or set TOOLCHAIN=<path>.xctoolchain." >&2
  exit 1
fi

# `swift sdk list` prints one name per line; matched with `case` so the check does not depend
# on grep being on PATH in whatever CI image this runs in.
case " $(swift sdk list 2>/dev/null | tr '\n' ' ') " in
  *" $SDK "*) ;;
  *)
    echo "build-android.sh: Swift SDK '$SDK' is not installed" >&2
    echo "  swift sdk install https://download.swift.org/swift-6.3.3-release/android/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz" >&2
    echo "  then link an NDK into it with its scripts/setup-android-sdk.sh." >&2
    exit 1
    ;;
esac

# The runtime .so files are not in the build directory, only in the SDK. macOS and Linux
# SwiftPM put installed SDKs in different places.
SDK_ROOT=""
for prefix in "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks"; do
  if [ -d "$prefix/$SDK.artifactbundle/swift-android" ]; then
    SDK_ROOT="$prefix/$SDK.artifactbundle/swift-android"
    break
  fi
done
if [ -z "$SDK_ROOT" ]; then
  echo "build-android.sh: '$SDK' is listed but its artifact bundle is missing" >&2
  echo "  Looked in ~/Library/org.swift.swiftpm/swift-sdks and ~/.swiftpm/swift-sdks." >&2
  exit 1
fi

# Selects the Android product in Package.swift. Exported, not per-command, because SwiftPM
# runs the manifest for --show-bin-path too and would otherwise report the host's path.
export WEBREADER_ANDROID=1

for triple in $ABIS; do
  arch="${triple%%-*}"
  case "$arch" in
    aarch64) abi="arm64-v8a"; ndk="aarch64-linux-android" ;;
    x86_64)  abi="x86_64";    ndk="x86_64-linux-android" ;;
    *)
      echo "build-android.sh: no Android ABI mapping for '$arch' (from '$triple')" >&2
      exit 1
      ;;
  esac

  swift build -c "$CONFIG" --swift-sdk "$triple"
  bin="$(swift build -c "$CONFIG" --swift-sdk "$triple" --show-bin-path)"

  dest="android/app/src/main/jniLibs/$abi"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp "$bin/libReaderKitAndroid.so" "$dest/"

  # The whole Swift runtime travels with the app, minus swift-testing and XCTest: those are
  # in the SDK for `swift test`, and shipping a test harness inside a release APK is silly.
  for lib in "$SDK_ROOT/swift-resources/usr/lib/swift-$arch/android/"*.so; do
    case "${lib##*/}" in
      libTesting.so|libXCTest.so|lib_TestingInterop.so|lib_Testing_Foundation.so) continue ;;
    esac
    cp "$lib" "$dest/"
  done
  # Not part of swift-resources: the runtime links against the NDK's libc++, and the platform
  # does not provide it.
  cp "$SDK_ROOT/ndk-sysroot/usr/lib/$ndk/libc++_shared.so" "$dest/"

  echo "Built $dest — $(find "$dest" -name '*.so' | wc -l | tr -d ' ') libraries, $(du -sh "$dest" | cut -f1)"
done
