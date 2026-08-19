// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeLive",
    // iOS is declared for `ClaudeLiveKit` alone: the companion app consumes the
    // library product, never the executable, which stays macOS-only in practice.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // What the iPhone companion's Xcode project links against.
        .library(name: "ClaudeLiveKit", targets: ["ClaudeLiveKit"])
    ],
    dependencies: [
        // Standard auto-update framework for apps distributed outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Everything both platforms need: the domain models, the status/alert
        // vocabulary, and the glow primitives. Foundation and SwiftUI only — no
        // AppKit outside a `canImport` guard, or the companion cannot compile it.
        .target(
            name: "ClaudeLiveKit",
            path: "Sources/ClaudeLiveKit"
        ),
        .executableTarget(
            name: "ClaudeLive",
            dependencies: [
                "ClaudeLiveKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClaudeLive",
            linkerSettings: [
                // The framework is copied into Contents/Frameworks by build.sh;
                // this is what lets the executable find it at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
