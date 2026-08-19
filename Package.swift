// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ModelMoor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ModelMoorCore", targets: ["ModelMoorCore"]),
        .library(name: "ModelMoorGateway", targets: ["ModelMoorGateway"]),
        .executable(name: "modelmoor", targets: ["ModelMoorCLI"]),
        .executable(name: "ModelMoorApp", targets: ["ModelMoor"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")
    ],
    targets: [
        .target(name: "ModelMoorCore"),
        .target(
            name: "ModelMoorGateway",
            dependencies: [
                "ModelMoorCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        ),
        .executableTarget(
            name: "ModelMoorCLI",
            dependencies: ["ModelMoorCore", "ModelMoorGateway"],
            path: "Sources/modelmoor"
        ),
        .executableTarget(
            name: "ModelMoor",
            dependencies: ["ModelMoorCore", "ModelMoorGateway"],
            path: "Sources/ModelMoorApp"
        ),
        .testTarget(
            name: "ModelMoorCoreTests",
            dependencies: ["ModelMoorCore"]
        ),
        .testTarget(
            name: "ModelMoorGatewayTests",
            dependencies: ["ModelMoorGateway"]
        )
    ]
)
