// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FIREFreedom",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FIRECore", targets: ["FIRECore"]),
        .library(name: "FIREBridgeKit", targets: ["FIREBridgeKit"]),
        .executable(name: "fire-bridge-cli", targets: ["FIREBridgeCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/CoreOffice/CoreXLSX.git",
            exact: "0.14.2"
        ),
    ],
    targets: [
        .target(
            name: "FIRECore",
            dependencies: [
                .product(name: "CoreXLSX", package: "CoreXLSX"),
            ]
        ),
        .target(
            name: "FIREBridgeKit",
            dependencies: ["FIRECore"],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "FIREBridgeCLI",
            dependencies: ["FIREBridgeKit"]
        ),
        .testTarget(
            name: "FIRECoreTests",
            dependencies: ["FIRECore"]
        ),
        .testTarget(
            name: "FIREBridgeKitTests",
            dependencies: ["FIREBridgeKit", "FIRECore"]
        ),
    ]
)
