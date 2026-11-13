// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let core: Target.Dependency = .product(name: "ZoroCore", package: "ZoroKit")
let router: Target.Dependency = .product(name: "ModelRouter", package: "ZoroKit")
let design: Target.Dependency = .product(name: "ZoroDesign", package: "ZoroDesign")

let package = Package(
    name: "ZoroLife",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LifeSupport", targets: ["LifeSupport"]),
        .library(name: "FitnessFeature", targets: ["FitnessFeature"]),
        .library(name: "PhotosFeature", targets: ["PhotosFeature"]),
        .library(name: "MusicFeature", targets: ["MusicFeature"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
        .package(path: "../ZoroDesign"),
    ],
    targets: [
        // Screen phases, error sentences, number and time formatting shared by the three features.
        .target(name: "LifeSupport", dependencies: [core, design], swiftSettings: settings),
        .target(name: "FitnessFeature", dependencies: ["LifeSupport", core, design], swiftSettings: settings),
        .target(name: "PhotosFeature", dependencies: ["LifeSupport", core, router, design], swiftSettings: settings),
        .target(name: "MusicFeature", dependencies: ["LifeSupport", core, design], swiftSettings: settings),

        .testTarget(name: "LifeSupportTests", dependencies: ["LifeSupport", core], swiftSettings: settings),
        .testTarget(
            name: "FitnessFeatureTests", dependencies: ["FitnessFeature", "LifeSupport", core, design],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(
            name: "PhotosFeatureTests", dependencies: ["PhotosFeature", "LifeSupport", core, design],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(
            name: "MusicFeatureTests", dependencies: ["MusicFeature", "LifeSupport", core, design],
            resources: [.copy("Fixtures")], swiftSettings: settings),
    ]
)
