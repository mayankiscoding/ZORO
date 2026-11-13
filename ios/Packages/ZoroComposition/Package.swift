// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

/// The composition root shared by the iPhone app and the Mac companion: builds `ZoroServices` from the
/// concrete implementations in every other package, registers the screens and card renderers, and runs
/// the app lifecycle (device channel, permission refresh, polite foreground work). Nothing else depends
/// on this package, so no other package had to change to compose the apps.
let package = Package(
    name: "ZoroComposition",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ZoroComposition", targets: ["ZoroComposition"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
        .package(path: "../ZoroDesign"),
        .package(path: "../ZoroVoice"),
        .package(path: "../ZoroDevice"),
        .package(path: "../ZoroPhotos"),
        .package(path: "../ZoroCommerce"),
        .package(path: "../ZoroLife"),
        .package(path: "../ZoroSystem"),
        .package(path: "../ZoroApp"),
    ],
    targets: [
        .target(
            name: "ZoroComposition",
            dependencies: [
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "AgentClient", package: "ZoroKit"),
                .product(name: "SecurityManager", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "MemoryClient", package: "ZoroKit"),
                .product(name: "PermissionManager", package: "ZoroKit"),
                .product(name: "ModelRouter", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
                .product(name: "AudioEngine", package: "ZoroVoice"),
                .product(name: "VoiceInterface", package: "ZoroVoice"),
                .product(name: "NativeActionBroker", package: "ZoroDevice"),
                .product(name: "HealthIntegration", package: "ZoroDevice"),
                .product(name: "MusicIntegration", package: "ZoroDevice"),
                .product(name: "PhotoIntelligence", package: "ZoroPhotos"),
                .product(name: "CommerceSupport", package: "ZoroCommerce"),
                .product(name: "ShoppingInterface", package: "ZoroCommerce"),
                .product(name: "FinancialInterface", package: "ZoroCommerce"),
                .product(name: "InvestmentsFeature", package: "ZoroCommerce"),
                .product(name: "LifeSupport", package: "ZoroLife"),
                .product(name: "FitnessFeature", package: "ZoroLife"),
                .product(name: "PhotosFeature", package: "ZoroLife"),
                .product(name: "MusicFeature", package: "ZoroLife"),
                .product(name: "SystemFeatures", package: "ZoroSystem"),
                .product(name: "ZoroAppUI", package: "ZoroApp"),
            ],
            swiftSettings: settings),
        .testTarget(
            name: "ZoroCompositionTests",
            dependencies: [
                "ZoroComposition",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "AgentClient", package: "ZoroKit"),
                .product(name: "SecurityManager", package: "ZoroKit"),
                .product(name: "ConversationManager", package: "ZoroKit"),
                .product(name: "PermissionManager", package: "ZoroKit"),
                .product(name: "ZoroDesign", package: "ZoroDesign"),
                .product(name: "NativeActionBroker", package: "ZoroDevice"),
                .product(name: "CommerceSupport", package: "ZoroCommerce"),
                .product(name: "SystemFeatures", package: "ZoroSystem"),
                .product(name: "ZoroAppUI", package: "ZoroApp"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: settings),
    ]
)
