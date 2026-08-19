// swift-tools-version:5.9
import PackageDescription

/// Quello che Mac e iPhone sanno entrambi.
///
/// Pacchetto a sé, e senza dipendenze, di proposito: l'app del Mac dipende da
/// Sparkle, che su iOS non ha senso, e finché il kit viveva dentro quel
/// pacchetto il progetto iPhone se la tirava dietro a ogni risoluzione. Qui non
/// c'è niente da scaricare e niente di specifico di una piattaforma.
let package = Package(
    name: "ClaudeLiveKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudeLiveKit", targets: ["ClaudeLiveKit"])
    ],
    targets: [
        .target(name: "ClaudeLiveKit"),
        .testTarget(name: "ClaudeLiveKitTests", dependencies: ["ClaudeLiveKit"])
    ]
)
