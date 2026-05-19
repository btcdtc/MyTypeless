// swift-tools-version:6.0
//
// Typeforme — macOS local voice dictation helper (v1).
// Bundle ID: com.btcdtc.typeforme.mac. Apple Silicon, macOS 14+.
//
// Build and test through the Xcode-backed scripts in scripts/.
// `scripts/build-app.sh` wraps the built executable into Typeforme.app with the
// Info.plist and entitlements from Resources/.
//
import PackageDescription

let package = Package(
    name: "Typeforme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typeforme", targets: ["Typeforme"]),
    ],
    dependencies: [
        // Global hotkey recorder / monitor.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMajor(from: "2.4.0")),
        // Argmax OSS WhisperKit (product `WhisperKit`) per spec §3 / §10.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", .upToNextMajor(from: "1.0.0")),
        // Local HTTP server for Bridge. Do not hand-roll HTTP parsing/keep-alive.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        .executableTarget(
            name: "Typeforme",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit",        package: "argmax-oss-swift"),
                .product(name: "Hummingbird",       package: "hummingbird"),
            ],
            path: "Sources/Typeforme",
            // Swift 6 strict concurrency requires invasive changes to NSLock
            // usage, KeyboardShortcuts.Name globals, and Carbon CFString globals.
            // Stay on the Swift 5 language mode for v1 — concurrency tightening
            // is a separate pass once the app is settled.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TypeformeTests",
            dependencies: ["Typeforme"],
            path: "Tests/TypeformeTests"
        ),
    ]
)
