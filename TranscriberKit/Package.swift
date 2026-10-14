// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranscriberKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .library(name: "AudioFeatures", targets: ["AudioFeatures"]),
        .library(name: "MediaDecoding", targets: ["MediaDecoding"]),
        .library(name: "SpeechDetection", targets: ["SpeechDetection"]),
        .library(name: "SubtitleExport", targets: ["SubtitleExport"]),
        .library(name: "SubtitlePostProcessing", targets: ["SubtitlePostProcessing"]),
        .library(name: "TranscriptionPipeline", targets: ["TranscriptionPipeline"]),
        .library(name: "WhisperCpp", targets: ["WhisperCpp"]),
        .library(name: "WhisperDecoding", targets: ["WhisperDecoding"]),
        .executable(name: "transcriber-cli", targets: ["transcriber-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TranscriberCore"),
        .target(name: "AudioFeatures"),
        .target(
            name: "MediaDecoding",
            dependencies: ["libavcodec", "libavformat", "libavutil", "libswresample"]
        ),
        .target(
            name: "SpeechDetection",
            dependencies: ["TranscriberCore", "AudioFeatures"]
        ),
        .target(
            name: "SubtitleExport",
            dependencies: ["TranscriberCore"]
        ),
        .target(
            name: "SubtitlePostProcessing",
            dependencies: ["TranscriberCore"]
        ),
        .target(
            name: "TranscriptionPipeline",
            dependencies: ["TranscriberCore"]
        ),
        .target(
            name: "WhisperDecoding",
            dependencies: ["TranscriberCore"]
        ),
        .target(
            name: "WhisperCpp",
            dependencies: ["TranscriberCore", "whisper"]
        ),
        .executableTarget(
            name: "transcriber-cli",
            dependencies: [
                "TranscriberCore",
                "MediaDecoding",
                "WhisperCpp",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        ),
        .testTarget(
            name: "AudioFeaturesTests",
            dependencies: ["AudioFeatures"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MediaDecodingTests",
            dependencies: ["MediaDecoding"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SpeechDetectionTests",
            dependencies: ["SpeechDetection"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SubtitleExportTests",
            dependencies: ["SubtitleExport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SubtitlePostProcessingTests",
            dependencies: ["SubtitlePostProcessing"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TranscriptionPipelineTests",
            dependencies: ["TranscriptionPipeline"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WhisperCppTests",
            dependencies: ["WhisperCpp"]
        ),
        .testTarget(
            name: "WhisperDecodingTests",
            dependencies: ["WhisperDecoding", "TranscriberCore"],
            resources: [.copy("Fixtures")]
        ),
        // whisper.cpp built by `make whisper-xcframework` (see the root Makefile).
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // FFmpeg built by `make ffmpeg-xcframeworks` (LGPL, dynamic).
        .binaryTarget(name: "libavcodec", path: "Vendor/libavcodec.xcframework"),
        .binaryTarget(name: "libavformat", path: "Vendor/libavformat.xcframework"),
        .binaryTarget(name: "libavutil", path: "Vendor/libavutil.xcframework"),
        .binaryTarget(name: "libswresample", path: "Vendor/libswresample.xcframework"),
    ]
)
