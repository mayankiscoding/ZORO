// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroVoice",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "VoiceInterface", targets: ["VoiceInterface"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
    ],
    targets: [
        .target(
            name: "AudioEngine",
            dependencies: [.product(name: "ZoroCore", package: "ZoroKit")],
            swiftSettings: settings),
        .target(
            name: "VoiceInterface",
            dependencies: [
                "AudioEngine",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "AgentClient", package: "ZoroKit"),
            ],
            swiftSettings: settings),

        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine"], swiftSettings: settings),
        .testTarget(
            name: "VoiceInterfaceTests",
            dependencies: [
                "VoiceInterface", "AudioEngine",
                .product(name: "ZoroCore", package: "ZoroKit"),
                .product(name: "AgentClient", package: "ZoroKit"),
            ],
            swiftSettings: settings),
    ]
)
