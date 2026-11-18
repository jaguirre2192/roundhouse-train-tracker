// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TrainTrackerCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "TrainTrackerCore", targets: ["TrainTrackerCore"]),
    ],
    targets: [
        .target(name: "TrainTrackerCore"),
        .testTarget(
            name: "TrainTrackerCoreTests",
            dependencies: ["TrainTrackerCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
