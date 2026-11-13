// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroDevice",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NativeActionBroker", targets: ["NativeActionBroker"]),
        .library(name: "HealthIntegration", targets: ["HealthIntegration"]),
        .library(name: "MusicIntegration", targets: ["MusicIntegration"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit")
    ],
    targets: [
        .target(
            name: "NativeActionBroker",
            dependencies: [.product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
        .target(
            name: "HealthIntegration",
            dependencies: [
                "NativeActionBroker",
                .product(name: "ZoroCore", package: "ZoroKit"),
            ],
            swiftSettings: settings),
        .target(
            name: "MusicIntegration",
            dependencies: [
                "NativeActionBroker",
                .product(name: "ZoroCore", package: "ZoroKit"),
            ],
            swiftSettings: settings),

        .testTarget(
            name: "NativeActionBrokerTests",
            dependencies: ["NativeActionBroker", .product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
        .testTarget(
            name: "HealthIntegrationTests",
            dependencies: ["HealthIntegration", "NativeActionBroker", .product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
        .testTarget(
            name: "MusicIntegrationTests",
            dependencies: ["MusicIntegration", "NativeActionBroker", .product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
    ]
)
