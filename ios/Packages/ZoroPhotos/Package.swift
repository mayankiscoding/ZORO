// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroPhotos",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PhotoIntelligence", targets: ["PhotoIntelligence"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
    ],
    targets: [
        .target(
            name: "PhotoIntelligence",
            dependencies: [.product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings,
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(
            name: "PhotoIntelligenceTests",
            dependencies: ["PhotoIntelligence", .product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
    ]
)
