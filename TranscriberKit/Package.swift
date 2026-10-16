// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranscriberKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .library(name: "AudioFeatures", targets: ["AudioFeatures"]),
        .library(name: "JobQueue", targets: ["JobQueue"]),
        .library(name: "LLMTranslation", targets: ["LLMTranslation"]),
        .library(name: "MediaDecoding", targets: ["MediaDecoding"]),
        .library(name: "SpeechDetection", targets: ["SpeechDetection"]),
        .library(name: "SubtitleExport", targets: ["SubtitleExport"]),
        .library(name: "SubtitlePostProcessing", targets: ["SubtitlePostProcessing"]),
        .library(name: "TranscriptionPipeline", targets: ["TranscriptionPipeline"]),
        .library(name: "WhisperCpp", targets: ["WhisperCpp"]),
        .library(name: "WhisperDecoding", targets: ["WhisperDecoding"]),
        .library(name: "WhisperMLX", targets: ["WhisperMLX"]),
        .executable(name: "transcriber-cli", targets: ["transcriber-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .target(name: "TranscriberCore"),
        .target(name: "AudioFeatures"),
        .target(
            name: "JobQueue",
            dependencies: [
                "TranscriberCore", "LLMTranslation", "MediaDecoding", "SpeechDetection", "SubtitleExport", "TranscriptionPipeline",
                "WhisperCpp", "WhisperDecoding", "WhisperMLX",
            ]
        ),
        .target(
            name: "LLMTranslation",
            dependencies: ["TranscriberCore"]
        ),
        .target(
            name: "MediaDecoding",
            dependencies: ["TranscriberCore", "libavcodec", "libavformat", "libavutil", "libswresample"]
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
            dependencies: [
                "TranscriberCore", "AudioFeatures", "MediaDecoding", "SpeechDetection",
                "SubtitlePostProcessing", "WhisperDecoding",
            ]
        ),
        .target(
            name: "WhisperDecoding",
            dependencies: ["TranscriberCore", "AudioFeatures"]
        ),
        .target(
            name: "WhisperMLX",
            dependencies: [
                "AudioFeatures", "WhisperDecoding",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "WhisperCpp",
            dependencies: ["TranscriberCore", "AudioFeatures", "WhisperDecoding", "whisper"]
        ),
        .executableTarget(
            name: "transcriber-cli",
            dependencies: [
                "TranscriberCore",
                "AudioFeatures",
                "LLMTranslation",
                "MediaDecoding",
                "SpeechDetection",
                "SubtitleExport",
                "TranscriptionPipeline",
                "WhisperCpp",
                "WhisperDecoding",
                "WhisperMLX",
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
            name: "JobQueueTests",
            dependencies: ["JobQueue", "LLMTranslation", "SubtitleExport", "TranscriberCore"]
        ),
        .testTarget(
            name: "LLMTranslationTests",
            dependencies: ["LLMTranslation", "TranscriberCore"]
        ),
        .testTarget(
            name: "MediaDecodingTests",
            dependencies: ["MediaDecoding", "TranscriberCore"],
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
