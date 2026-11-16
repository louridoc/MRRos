// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TFKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TFKit", targets: ["TFKit"]),
    ],
    dependencies: [
        .package(path: "../ROSMessages"),
    ],
    targets: [
        .target(
            name: "TFKit",
            dependencies: [
                .product(name: "ROSMessages", package: "ROSMessages"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "TFKitTests",
            dependencies: ["TFKit"]
        ),
    ]
)
