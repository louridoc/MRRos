// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlignmentKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AlignmentKit", targets: ["AlignmentKit"]),
    ],
    dependencies: [
        .package(path: "../TFKit"),
        .package(path: "../LiDARScan"),
    ],
    targets: [
        .target(
            name: "AlignmentKit",
            dependencies: [
                .product(name: "TFKit", package: "TFKit"),
                .product(name: "LiDARScan", package: "LiDARScan"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AlignmentKitTests",
            dependencies: ["AlignmentKit"]
        ),
    ]
)
