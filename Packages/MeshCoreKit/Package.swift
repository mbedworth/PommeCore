// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeshCoreKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11)
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
            path: "Sources/MeshCoreKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line harness for exercising a real radio (macOS only — it needs
        // CoreBluetooth central mode). Not linked into the app; it exists so the
        // firmware smoke test in docs/FIRMWARE_COMPAT.md is a command, not a
        // manual pass through the UI.
        .executableTarget(
            name: "meshctl",
            dependencies: ["MeshCoreKit"],
            path: "Sources/meshctl",
            // Embedded into the binary at link time by scripts/meshctl.sh, not
            // bundled as a resource — see that script for why.
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeshCoreKitTests",
            dependencies: ["MeshCoreKit"]
        )
    ]
)
