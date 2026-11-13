// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroApp",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ZoroAppUI", targets: ["ZoroAppUI"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
        .package(path: "../ZoroDesign"),
    ],
    targets: [
        .target(
            name: "ZoroAppUI",
            dependencies: [
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "SecurityManager", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
            ],
            swiftSettings: settings),
        // Renders Home, Live Voice and the approval sheet to docs/design/snapshots/app-*.png. macOS host tool.
        .executableTarget(
            name: "ZoroAppSnapshots",
            dependencies: [
                "ZoroAppUI",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
            ],
            swiftSettings: settings),
        .testTarget(
            name: "ZoroAppUITests",
            dependencies: [
                "ZoroAppUI",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "SecurityManager", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
            ],
            swiftSettings: settings),
    ]
)
