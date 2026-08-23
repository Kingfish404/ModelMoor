// swift-tools-version: 6.1

import PackageDescription

// This package remains as a standalone development and compatibility entry
// point. Its executable reuses the root package's TUIWidgets and ModelMoorTUI
// implementation, so it behaves exactly like the default root CLI.
let package = Package(
    name: "ModelMoorTUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "modelmoor-tui", targets: ["modelmoor-tui"])
    ],
    dependencies: [
        .package(name: "ModelMoor", path: "../.."),
        .package(
            url: "https://github.com/migueldeicaza/TermKit.git",
            revision: "2cdfc96f9c524251ae1f517a440f28150182b7c2"
        )
    ],
    targets: [
        .executableTarget(
            name: "modelmoor-tui",
            dependencies: [
                .product(name: "TUIWidgets", package: "ModelMoor"),
                .product(name: "ModelMoorApplication", package: "ModelMoor"),
                .product(name: "ModelMoorCore", package: "ModelMoor"),
                .product(name: "ModelMoorGateway", package: "ModelMoor"),
                .product(name: "ModelMoorSystem", package: "ModelMoor"),
                .product(name: "TermKit", package: "TermKit")
            ],
            path: "Sources/modelmoor-tui"
        ),
        .testTarget(
            name: "ModelMoorTUITests",
            dependencies: [
                .product(name: "TUIWidgets", package: "ModelMoor"),
                .product(name: "ModelMoorApplication", package: "ModelMoor"),
                .product(name: "ModelMoorCore", package: "ModelMoor"),
                .product(name: "ModelMoorGateway", package: "ModelMoor"),
                .product(name: "ModelMoorSystem", package: "ModelMoor")
            ],
            path: "Tests/ModelMoorTUITests"
        )
    ]
)
