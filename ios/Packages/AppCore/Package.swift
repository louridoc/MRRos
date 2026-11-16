// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(path: "../ROSBridgeClient"),
        .package(path: "../TFKit"),
        .package(path: "../URDFKit"),
        .package(path: "../ARBridgeTransport"),
        .package(path: "../LiDARScan"),
        .package(path: "../AlignmentKit"),
        .package(path: "../MeshProvider"),
        .package(path: "../RobotModel"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "ROSBridgeClient", package: "ROSBridgeClient"),
                .product(name: "TFKit", package: "TFKit"),
                .product(name: "URDFKit", package: "URDFKit"),
                .product(name: "ARBridgeTransport", package: "ARBridgeTransport"),
                .product(name: "LiDARScan", package: "LiDARScan"),
                .product(name: "AlignmentKit", package: "AlignmentKit"),
                .product(name: "MeshProvider", package: "MeshProvider"),
                .product(name: "RobotModel", package: "RobotModel"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"]
        ),
    ]
)
