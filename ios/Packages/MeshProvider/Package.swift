// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshProvider",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshProvider", targets: ["MeshProvider"]),
    ],
    dependencies: [
        .package(path: "../ARBridgeTransport"),
    ],
    targets: [
        .target(
            name: "MeshProvider",
            dependencies: [
                .product(name: "ARBridgeTransport", package: "ARBridgeTransport"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "MeshProviderTests",
            dependencies: [
                "MeshProvider",
                .product(name: "ARBridgeTransport", package: "ARBridgeTransport"),
            ]
        ),
    ]
)
