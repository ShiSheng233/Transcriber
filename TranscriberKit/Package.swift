// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranscriberKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .library(name: "WhisperCpp", targets: ["WhisperCpp"]),
    ],
    targets: [
        .target(name: "TranscriberCore"),
        .target(
            name: "WhisperCpp",
            dependencies: ["TranscriberCore", "whisper"]
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
