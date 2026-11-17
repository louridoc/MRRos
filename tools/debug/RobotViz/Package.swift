// swift-tools-version: 6.0
// Mac-side visualization of the real RobotModel/RealityKit pipeline — no phone needed.
// Usage: see tools/debug/render_robot.sh
import PackageDescription

let package = Package(
    name: "RobotViz",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../ios/Packages/URDFKit"),
        .package(path: "../../../ios/Packages/MeshProvider"),
        .package(path: "../../../ios/Packages/RobotModel"),
        .package(path: "../../../ios/Packages/AlignmentKit"),
    ],
    targets: [
        .executableTarget(
            name: "RobotViz",
            dependencies: [
                .product(name: "URDFKit", package: "URDFKit"),
                .product(name: "MeshProvider", package: "MeshProvider"),
                .product(name: "RobotModel", package: "RobotModel"),
                .product(name: "AlignmentKit", package: "AlignmentKit"),
            ]
        ),
    ]
)
