// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoNotType",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoNotTypeCore", targets: ["DoNotTypeCore"]),
        .executable(name: "dnt-eval", targets: ["dnt-eval"]),
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
        .testTarget(name: "DoNotTypeCoreTests", dependencies: ["DoNotTypeCore"]),
    ]
)
