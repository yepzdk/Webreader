# Android host

The Android app (#9). Kotlin owns the `Activity`, the `WebView`, intents and the Storage
Access Framework; **ReaderKit owns every rule** — the generated pages, the page-state
machine, extraction, the seventeen script messages, URL cleaning, recents, suggestions and
the sync fold — cross-compiled to a `.so` by the official Swift SDK for Android. Nothing in
this directory reimplements reader logic; it calls across and executes what comes back.

| File | Purpose |
| --- | --- |
| `app/src/main/kotlin/dk/yepz/webreader/ReaderBridge.kt` | The one native method, `call(name, jsonArgs)`, plus a typed helper per contract call. |
| `app/src/main/kotlin/dk/yepz/webreader/MainActivity.kt` | The whole app: the web view, the `WebViewClient`, the `readerHost` JavaScript interface, the command executor, intents. |
| `app/src/main/kotlin/dk/yepz/webreader/SyncFolder.kt` | The shared sync folder as SAF sees it: `<chosen tree>/WebReader/*.json`. I/O only. |
| `app/build.gradle.kts` | Application id `dk.yepz.webreader`, `minSdk 28`, `targetSdk 36`, one APK per ABI. |

## Build ReaderKit first

`./gradlew :app:assembleDebug` fails with `UnsatisfiedLinkError` at runtime — or packages an
APK that dies on launch — unless the native libraries exist. They are **not** in git:

```sh
Scripts/build-android.sh
```

writes `android/app/src/main/jniLibs/<abi>/*.so`: `libReaderKitAndroid.so` (ReaderKit plus
the JNI shim) and the two dozen Swift runtime libraries the app has to carry, because Android
ships none of them. Around 104 MB per ABI unstripped. It clears the whole `jniLibs` tree
first, so what is there afterwards is exactly what that run built. Run it from the repository
root; see the comments at the top of that script for `TOOLCHAIN`, `SDK`, `ABIS` and `CONFIG`.

Add the emulator ABI when you need one:

```sh
ABIS="aarch64-unknown-linux-android28 x86_64-unknown-linux-android28" Scripts/build-android.sh
```

## What to install

| Tool | Version used | Notes |
| --- | --- | --- |
| JDK | 17 or newer | Gradle 9.7 and AGP 9.3 both run on 26. |
| Android SDK | platform 36, build-tools 36.0.0+ | `ANDROID_HOME` must point at it, or write `sdk.dir` into `local.properties`. |
| Gradle | none | The wrapper is checked in; `./gradlew` fetches 9.7.1 on first run. |
| NDK | optional | Only for stripping — see below. |

The Swift toolchain and the Swift SDK for Android are `Scripts/build-android.sh`'s
dependencies, not this module's.

## Build and run

```sh
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
adb shell am start -n dk.yepz.webreader/.MainActivity
```

`splits.abi` produces one APK per ABI and no universal one: the stripped Swift runtime is the
bulk of the app, so a release APK is around 74 MB per ABI, every device installs exactly one
of them, and a universal APK would simply be both.

Which ABIs it splits on is read off `app/src/main/jniLibs/` at configuration time rather than
written down, so the APK set always matches what `Scripts/build-android.sh` last produced —
build arm64 only and there is one APK to install. A checkout that has never run the script
has no native code to split on at all, and Gradle then emits a single APK that compiles and
lints but dies in `System.loadLibrary` on launch.

Opening a link the way the app is meant to be used:

```sh
adb shell am start -a android.intent.action.VIEW -d "https://example.com/article"
```

`ACTION_VIEW` on `http`/`https` and `ACTION_SEND` on `text/plain` are the two intent filters,
so WebReader appears in "Open with" and in the share sheet, and can be chosen as the default
browser. Installing it adds an option and takes none away.

## Symbol stripping is optional, and off by default

AGP strips packaged `.so` files with the NDK's `llvm-strip`. With no NDK it says so and
packages them as they are:

```
Unable to strip the following libraries, packaging them as they are: libFoundation.so, …
```

The APK still works; it is around 104 MB per ABI instead of 74. Point the build at the NDK the
Swift SDK was linked against to get the smaller one — the revision is read off the NDK itself,
so nothing here has to agree with a pinned version:

```sh
ANDROID_NDK_ROOT=/path/to/android-ndk-r27d ./gradlew :app:assembleDebug
# or
./gradlew :app:assembleDebug -Pwebreader.ndkPath=/path/to/android-ndk-r27d
```

## Two native views, and no toolbar

There is no action bar and no menu, which is not a gap: `Platform.android` already tells the
generated pages there are no keyboard commands to advertise, and the page chrome carries Home,
Settings, Aa and recents itself — the same shape as the iOS host. The app draws exactly two
things of its own, both Material 3:

- an indeterminate `LinearProgressIndicator` over the top edge while a foreign page loads.
  Indeterminate deliberately: the fraction curve is `ReaderKit.LoadProgress`, which the native
  facade does not expose, and a made-up percentage would be worse than none;
- a `Snackbar` for the one thing that has no page to report it — the sync folder the user just
  picked being unreadable or unwritable.

The web view is inset by the system bars rather than drawn under them. The pages place their
chrome with `env(safe-area-inset-*)`, which on iOS is the whole answer, but Android WebView
resolves those values from display cutouts only — the status bar and the gesture bar are not in
them — so the host does the insetting the pages cannot see to do.

## Permissions

`INTERNET`, and `ACCESS_NETWORK_STATE`. The second is not incidental: WebView reports a dead
radio as `ERROR_HOST_LOOKUP`, which `OfflineFallback.classify` would read as "that site does
not exist". Asking the system whether there is a network at all is the same question the GTK
host puts to GLib, and it is what keeps one shared, tested classification instead of a third
host-shaped copy. `android:usesCleartextTraffic="false"`.

## Sync

`ACTION_OPEN_DOCUMENT_TREE` picks a folder; the grant is persisted with
`takePersistableUriPermission`, and `ContentResolver.getPersistedUriPermissions` is the *only*
record of it — a copy in `SharedPreferences` could only ever disagree with the system after the
user revokes the grant. A cycle reads every `<deviceID>.json` under `<chosen tree>/WebReader/`,
hands the contents to `syncPeers`, and writes back the one file the reply names. Nothing here
parses a device file: the fold is ReaderKit's.

The settings page's Sync section exists only because the host says so: `syncStatus` carries
the folder to show and the one-line summary, and `SettingsPage` draws the section only for a
non-empty summary — so a device that has never been asked shows no dead control. It is called
once after `start`, whenever the picker lands a folder, and after every cycle.

This device's file name is `<ANDROID_ID>.json`. That id is stable for the life of the install,
unique per device, and already hex, so it is read rather than stored — a preferences file whose
only content is a value the system already keeps would be a second source of truth for nothing.
The summary's "last synced" is in memory only: a cycle runs on every resume, so the one moment
it could be stale is a cold start before the first cycle lands, and "Waiting for the first
sync…" is exactly the true answer then.

There is no `SharedPreferences` for reader state at all. Swift is handed `filesDir` and
`cacheDir` once, by `start`, and owns its own persistence through `ReaderKit.FileStore` and
`ReaderKit.ArticleCache` — exactly as the Linux host does.
