// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroDesign",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ZoroDesign", targets: ["ZoroDesign"]),
    ],
    targets: [
        // Resources: the Devanagari serif (OFL), artwork and earcons. Every file is listed in assets/LICENSES.md.
        .target(name: "ZoroDesign", resources: [.process("Resources")], swiftSettings: settings),
        // Renders orb states and key components to PNG (docs/design/snapshots). macOS host tool.
        .executableTarget(name: "ZoroDesignSnapshots", dependencies: ["ZoroDesign"], swiftSettings: settings),
        .testTarget(name: "ZoroDesignTests", dependencies: ["ZoroDesign"], swiftSettings: settings),
    ]
)
