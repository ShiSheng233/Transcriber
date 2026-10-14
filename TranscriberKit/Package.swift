// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranscriberKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .library(name: "WhisperCpp", targets: ["WhisperCpp"]),
        .executable(name: "transcriber-cli", targets: ["transcriber-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TranscriberCore"),
        .target(
            name: "WhisperCpp",
            dependencies: ["TranscriberCore", "whisper"]
        ),
        .executableTarget(
            name: "transcriber-cli",
            dependencies: [
                "TranscriberCore",
                "WhisperCpp",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        ),
        .testTarget(
            name: "WhisperCppTests",
            dependencies: ["WhisperCpp"]
        ),
        // whisper.cpp built by `make whisper-xcframework` (see the root Makefile).
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    ]
)
