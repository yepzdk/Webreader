// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "webreader",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Platform-neutral reader logic, shared by the macOS app and the future iOS app.
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
        // The macOS app's executable; Scripts/build-app.sh wraps it in WebReader.app.
        .executable(name: "WebReader", targets: ["WebReader"]),
    ],
    targets: [
        .target(name: "ReaderKit"),
        .executableTarget(name: "WebReader", dependencies: ["ReaderKit"]),
        .testTarget(name: "ReaderKitTests", dependencies: ["ReaderKit"]),
    ]
)
