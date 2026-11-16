// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ARBridgeTransport",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ARBridgeTransport", targets: ["ARBridgeTransport"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "ARBridgeTransport",
            dependencies: [
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ARBridgeTransportTests",
            dependencies: ["ARBridgeTransport"]
        ),
    ]
)
