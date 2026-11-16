// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ROSBridgeClient",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ROSBridgeClient", targets: ["ROSBridgeClient"]),
    ],
    dependencies: [
        .package(path: "../ROSMessages"),
    ],
    targets: [
        .target(
            name: "ROSBridgeClient",
            dependencies: [
                .product(name: "ROSMessages", package: "ROSMessages"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ROSBridgeClientTests",
            dependencies: ["ROSBridgeClient"],
            resources: [.copy("../Fixtures")]
        ),
    ]
)
