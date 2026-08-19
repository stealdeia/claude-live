// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeLive",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Standard auto-update framework for apps distributed outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Everything both platforms share. Its own package, so the iPhone project
        // can depend on it without dragging Sparkle — which is macOS-only — into
        // its dependency graph.
        .package(path: "ClaudeLiveKit")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeLive",
            dependencies: [
                .product(name: "ClaudeLiveKit", package: "ClaudeLiveKit"),
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
