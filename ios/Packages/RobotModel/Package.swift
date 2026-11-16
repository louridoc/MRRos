// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RobotModel",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RobotModel", targets: ["RobotModel"]),
    ],
    dependencies: [
        .package(path: "../URDFKit"),
        .package(path: "../MeshProvider"),
        .package(path: "../TFKit"),
    ],
    targets: [
        .target(
            name: "RobotModel",
            dependencies: [
                .product(name: "URDFKit", package: "URDFKit"),
                .product(name: "MeshProvider", package: "MeshProvider"),
                .product(name: "TFKit", package: "TFKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RobotModelTests",
            dependencies: ["RobotModel"]
        ),
    ]
)
