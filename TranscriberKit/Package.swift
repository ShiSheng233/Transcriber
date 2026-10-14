// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranscriberKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
    ],
    targets: [
        .target(name: "TranscriberCore"),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        ),
    ]
)
