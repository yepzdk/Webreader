// swift-tools-version:5.9
import PackageDescription

// The AppKit host only exists on macOS. Guarding the target (rather than relying on the
// `platforms:` list, which SwiftPM only consults for Apple platforms) is what lets
// `swift build` / `swift test` run ReaderKit and its tests on Linux, where the GTK host
// for issue #16 lives.
#if os(macOS)
let hostProducts: [Product] = [
    // The macOS app's executable; Scripts/build-app.sh wraps it in WebReader.app.
    .executable(name: "WebReader", targets: ["WebReader"])
]
let hostTargets: [Target] = [
    .executableTarget(name: "WebReader", dependencies: ["ReaderKit"])
]
#else
let hostProducts: [Product] = [
    // The command name a `.desktop` `Exec=` line and a Hyprland bind invoke, hence lowercase.
    .executable(name: "webreader", targets: ["WebReaderGTK"])
]
let hostTargets: [Target] = [
    // Header-only C shim: the GTK/GObject macros and varargs Swift's ClangImporter cannot
    // see. `webkitgtk-6.0.pc` requires gtk4, so one pkg-config name covers every -I/-l.
    .systemLibrary(
        name: "CWebKitGTK",
        path: "Sources/CWebKitGTK",
        pkgConfig: "webkitgtk-6.0",
        providers: [.apt(["libwebkitgtk-6.0-dev"])]
    ),
    // The GTK4 + WebKitGTK host; the Linux counterpart of Sources/WebReader.
    .executableTarget(name: "WebReaderGTK", dependencies: ["ReaderKit", "CWebKitGTK"])
]
#endif

let package = Package(
    name: "webreader",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Platform-neutral reader logic, shared by the macOS app and the future iOS app.
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
    ] + hostProducts,
    targets: [
        .target(name: "ReaderKit"),
        .testTarget(name: "ReaderKitTests", dependencies: ["ReaderKit"]),
    ] + hostTargets
)
