// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoNotType",
    // iOS is here for DoNotTypeCore only — the app and eval targets are macOS-hosted.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DoNotTypeCore", targets: ["DoNotTypeCore"]),
        // Two command-line tools, with different jobs. `dnt-eval` measures the prompt — it runs
        // cases and prints scores, and only a contributor changing PROMPT.md needs it. `dnt` uses
        // the product: transcribe a file, read the log, inspect the history, check the key.
        .executable(name: "dnt", targets: ["dnt"]),
        .executable(name: "dnt-eval", targets: ["dnt-eval"]),
        // Named DoNotTypeMac, not DoNotType: the iOS project consumes this package and has its
        // own target called DoNotType. Xcode resolves the two by name and would intermittently
        // try to build the macOS executable — AppKit, ScreenCaptureKit and all — for iOS. The
        // bundle's binary is still called DoNotType; the Makefile renames it on copy.
        .executable(name: "DoNotTypeMac", targets: ["DoNotTypeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // Silero VAD ships as ONNX so the same model and thresholds run on every platform.
        // Pinned exactly: inference runtimes are part of the product, not build-time tooling.
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            exact: "1.24.2"),
    ],
    targets: [
        // Pure logic. Deliberately free of AppKit so the eval harness runs headless in CI.
        .target(
            name: "DoNotTypeCore",
            dependencies: [
                .product(
                    name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            resources: [
                .copy("Resources/silero_vad.onnx"),
                .copy("Resources/SILERO-VAD-NOTICE.txt"),
            ]),
        .executableTarget(
            name: "dnt",
            dependencies: [
                "DoNotTypeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "dnt-eval",
            dependencies: [
                "DoNotTypeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The menu-bar app. `make app` wraps this binary in a signed .app bundle; the plist and
        // entitlements live in Resources/ rather than an .xcodeproj so they stay reviewable.
        .executableTarget(name: "DoNotTypeApp", dependencies: ["DoNotTypeCore"]),
        .testTarget(name: "DoNotTypeCoreTests", dependencies: ["DoNotTypeCore"]),
        // Hits the live API and costs money, so every test skips unless DNT_INTEGRATION=1.
        // Run with: DNT_INTEGRATION=1 swift test --filter IntegrationTests
        .testTarget(name: "IntegrationTests", dependencies: ["DoNotTypeCore"]),
    ]
)
