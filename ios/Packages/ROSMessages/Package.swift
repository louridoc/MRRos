// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ROSMessages",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ROSMessages", targets: ["ROSMessages"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "ROSMessages",
            dependencies: [
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ROSMessagesTests",
            dependencies: ["ROSMessages"]
        ),
    ]
)
