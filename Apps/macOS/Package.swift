// swift-tools-version: 6.1

import PackageDescription

// The macOS menu bar app lives in its own package so the root package
// (ModelMoorCore / ModelMoorSystem / ModelMoorGateway / modelmoor CLI)
// stays buildable and testable on Linux. See docs/PLAN.md milestone B.
let package = Package(
    name: "ModelMoorApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ModelMoorApp", targets: ["ModelMoor"])
    ],
    dependencies: [
        .package(name: "ModelMoor", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ModelMoor",
            dependencies: [
                .product(name: "ModelMoorCore", package: "ModelMoor"),
                .product(name: "ModelMoorSystem", package: "ModelMoor"),
                .product(name: "ModelMoorGateway", package: "ModelMoor"),
                .product(name: "ModelMoorApplication", package: "ModelMoor")
            ],
            path: "Sources/ModelMoor",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ModelMoorAppTests",
            dependencies: ["ModelMoor"],
            path: "Tests/ModelMoorAppTests"
        )
    ]
)
