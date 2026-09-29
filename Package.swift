// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenNotch",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet speech-to-text on the Apple Neural Engine (Apache-2.0).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        // Signed, notarized auto-updates (MIT).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenNotch",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OpenNotch",
            linkerSettings: [
                // Sparkle.framework is embedded in OpenNotch.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ],
    // Swift 5 mode: the app leans on AppKit callbacks and C event taps, where strict
    // concurrency checking costs more ceremony than it buys.
    swiftLanguageVersions: [.v5]
)
