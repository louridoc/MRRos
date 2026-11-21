// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SceneLibrary",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SceneLibrary", targets: ["SceneLibrary"]),
    ],
    dependencies: [
        .package(path: "../LiDARScan"),
        .package(path: "../AlignmentKit"),
    ],
    targets: [
        .target(
            name: "SceneLibrary",
            dependencies: [
                .product(name: "LiDARScan", package: "LiDARScan"),
                .product(name: "AlignmentKit", package: "AlignmentKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SceneLibraryTests",
            dependencies: ["SceneLibrary"]
        ),
    ]
)
