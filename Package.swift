// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ModelMoor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ModelMoorCore", targets: ["ModelMoorCore"]),
        .library(name: "ModelMoorSystem", targets: ["ModelMoorSystem"]),
        .library(name: "ModelMoorGateway", targets: ["ModelMoorGateway"]),
        .library(name: "ModelMoorApplication", targets: ["ModelMoorApplication"]),
        .library(name: "TUIWidgets", targets: ["TUIWidgets"]),
        .library(name: "ModelMoorTUI", targets: ["ModelMoorTUI"]),
        .executable(name: "modelmoor", targets: ["ModelMoorCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.1"),
        // The TUI uses SwiftTerm's portable terminal core. CI removes the
        // optional Metal resource declaration after SwiftPM resolves it.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(
            url: "https://github.com/migueldeicaza/TermKit.git",
            // CI applies Scripts/patch-termkit-swiftpm.sh after checkout to
            // normalize TermKit's platform-dependent wchar_t overloads.
            revision: "2cdfc96f9c524251ae1f517a440f28150182b7c2"
        )
    ],
    targets: [
        .target(name: "ModelMoorCore"),
        .target(
            name: "ModelMoorSystem",
            dependencies: ["ModelMoorCore"]
        ),
        .target(
            name: "ModelMoorGateway",
            dependencies: [
                "ModelMoorCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        ),
        // Presentation-independent policies (for example prepared search
        // queries) live here so GUI and TUI keep identical interaction rules.
        .target(
            name: "ModelMoorApplication",
            dependencies: ["ModelMoorCore", "ModelMoorSystem", "ModelMoorGateway"]
        ),
        .target(
            name: "TUIWidgets",
            dependencies: ["ModelMoorApplication", "ModelMoorCore", "ModelMoorGateway"],
            path: "Apps/TUI/Sources/TUIWidgets"
        ),
        .target(
            name: "ModelMoorTUI",
            dependencies: [
                "TUIWidgets",
                "ModelMoorApplication",
                "ModelMoorCore",
                "ModelMoorGateway",
                "ModelMoorSystem",
                .product(name: "TermKit", package: "TermKit")
            ],
            path: "Apps/TUI/Sources/modelmoor-tui",
            exclude: ["ModelMoorTUI.swift"]
        ),
        .executableTarget(
            name: "ModelMoorCLI",
            dependencies: [
                "ModelMoorCore",
                "ModelMoorSystem",
                "ModelMoorGateway",
                "ModelMoorApplication",
                "ModelMoorTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/modelmoor"
        ),
        .testTarget(
            name: "ModelMoorCoreTests",
            dependencies: ["ModelMoorCore", "ModelMoorSystem"]
        ),
        .testTarget(
            name: "ModelMoorApplicationTests",
            dependencies: ["ModelMoorApplication", "ModelMoorSystem"]
        ),
        .testTarget(
            name: "ModelMoorGatewayTests",
            dependencies: ["ModelMoorGateway"]
        )
    ]
)
