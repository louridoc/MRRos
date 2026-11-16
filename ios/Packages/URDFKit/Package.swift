// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "URDFKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "URDFKit", targets: ["URDFKit"]),
    ],
    dependencies: [
        // test-only: decoding the recorded /tf and /joint_states fixtures
        .package(path: "../ROSMessages"),
    ],
    targets: [
        .target(
            name: "URDFKit",
            dependencies: [],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "URDFKitTests",
            dependencies: [
                "URDFKit",
                .product(name: "ROSMessages", package: "ROSMessages"),
            ],
            resources: [.copy("../Fixtures")]
        ),
    ]
)
