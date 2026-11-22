// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XeylrouteCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "XeylrouteCore",
            targets: ["XeylrouteCore"]
        ),
    ],
    targets: [
        .target(
            name: "XeylrouteCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "XeylrouteCoreTests",
            dependencies: ["XeylrouteCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
