// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroSystem",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SystemFeatures", targets: ["SystemFeatures"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
        .package(path: "../ZoroDesign"),
    ],
    targets: [
        .target(
            name: "SystemFeatures",
            dependencies: [
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "MemoryClient", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
            ],
            swiftSettings: settings),
        .testTarget(
            name: "SystemFeaturesTests",
            dependencies: [
                "SystemFeatures",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "MemoryClient", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
            ],
            swiftSettings: settings),
    ]
)
