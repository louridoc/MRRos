// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiDARScan",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LiDARScan", targets: ["LiDARScan"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "LiDARScan",
            dependencies: [
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LiDARScanTests",
            dependencies: ["LiDARScan"]
        ),
    ]
)
