// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

/// The Mac companion as a SwiftPM executable, so the real app compiles and runs its smoke test on a
/// machine without Xcode (`scripts/swiftpm.sh macos build`). `project.yml` builds the same sources into
/// the bundled, signed, sandboxed app.
let package = Package(
    name: "ZOROMac",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .executable(name: "ZOROMac", targets: ["ZOROMac"]),
    ],
    dependencies: [
        .package(path: "../ios/Packages/ZoroComposition"),
        .package(path: "../ios/Packages/ZoroApp"),
        .package(path: "../ios/Packages/ZoroKit"),
        .package(path: "../ios/Packages/ZoroDesign"),
        .package(path: "../ios/Packages/ZoroDevice"),
    ],
    targets: [
        .executableTarget(
            name: "ZOROMac",
            dependencies: [
                .product(name: "ZoroComposition", package: "ZoroComposition"),
                .product(name: "ZoroAppUI", package: "ZoroApp"),
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
                .product(name: "NativeActionBroker", package: "ZoroDevice"),
            ],
            path: "ZOROMac",
            swiftSettings: settings),
        .testTarget(
            name: "ZOROMacTests",
            dependencies: [
                "ZOROMac",
                .product(name: "ZoroComposition", package: "ZoroComposition"),
                .product(name: "ZoroAppUI", package: "ZoroApp"),
                .product(name: "ZoroCore", package: "ZoroKit"),
            ],
            path: "Tests/ZOROMacTests",
            swiftSettings: settings),
    ]
)
