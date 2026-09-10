// swift-tools-version:5.9
import PackageDescription

// The AppKit host only exists on macOS. Guarding the target (rather than relying on the
// `platforms:` list, which SwiftPM only consults for Apple platforms) is what lets
// `swift build` / `swift test` run ReaderKit and its tests on Linux, where the GTK host
// for issue #16 lives.
//
// `ReaderWebKit` sits in the same branch because WebKit is an Apple framework: WebKitGTK is
// a different API with a different name. The manifest is compiled on the *build* machine, so
// a Mac building for iOS takes this branch too — which is what lets the Xcode iOS target
// depend on the same library the AppKit host uses.
#if os(macOS)
let hostProducts: [Product] = [
    // The macOS app's executable; Scripts/build-app.sh wraps it in WebReader.app.
    .executable(name: "WebReader", targets: ["WebReader"]),
    // The WKWebView half of a host, shared by the AppKit shell and the iOS one (#6).
    .library(name: "ReaderWebKit", targets: ["ReaderWebKit"]),
]
let hostTargets: [Target] = [
    .target(name: "ReaderWebKit", dependencies: ["ReaderKit"]),
    // Drives the controller through a real WKWebView and the real generated pages; the
    // wiring it covers (message registration, page-state gates, the shell's services) is
    // exactly what a second host is most likely to get wrong.
    .testTarget(name: "ReaderWebKitTests", dependencies: ["ReaderWebKit", "ReaderKit"]),
    .executableTarget(name: "WebReader", dependencies: ["ReaderKit", "ReaderWebKit"]),
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
