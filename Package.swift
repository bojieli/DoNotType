// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoNotType",
    // iOS is here for DoNotTypeCore only — the app and eval targets are macOS-hosted.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DoNotTypeCore", targets: ["DoNotTypeCore"]),
        .executable(name: "dnt-eval", targets: ["dnt-eval"]),
        .executable(name: "DoNotType", targets: ["DoNotTypeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Pure logic. Deliberately free of AppKit so the eval harness runs headless in CI.
        .target(name: "DoNotTypeCore"),
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
