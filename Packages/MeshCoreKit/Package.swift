// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeshCoreKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "MeshCoreKit",
            targets: ["MeshCoreKit"]
        )
    ],
    targets: [
        .target(
            name: "MeshCoreKit",
            path: "Sources/MeshCoreKit"
        ),
        .testTarget(
            name: "MeshCoreKitTests",
            dependencies: ["MeshCoreKit"]
        )
    ]
)
