// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "ZoroKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ZoroCore", targets: ["ZoroCore"]),
        .library(name: "AgentClient", targets: ["AgentClient"]),
        .library(name: "SecurityManager", targets: ["SecurityManager"]),
        .library(name: "ConversationManager", targets: ["ConversationManager"]),
        .library(name: "MemoryClient", targets: ["MemoryClient"]),
        .library(name: "PermissionManager", targets: ["PermissionManager"]),
        .library(name: "ModelRouter", targets: ["ModelRouter"]),
    ],
    targets: [
        .target(name: "ZoroCore", swiftSettings: settings),
        .target(name: "AgentClient", dependencies: ["ZoroCore"], swiftSettings: settings),
        .target(name: "SecurityManager", dependencies: ["ZoroCore"], swiftSettings: settings),
        .target(name: "ConversationManager", dependencies: ["ZoroCore"], swiftSettings: settings),
        .target(name: "MemoryClient", dependencies: ["ZoroCore"], swiftSettings: settings),
        .target(name: "PermissionManager", dependencies: ["ZoroCore"], swiftSettings: settings),
        .target(name: "ModelRouter", dependencies: ["ZoroCore"], swiftSettings: settings),

        .testTarget(
            name: "ZoroCoreTests", dependencies: ["ZoroCore"],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(name: "AgentClientTests", dependencies: ["AgentClient", "ZoroCore"], swiftSettings: settings),
        .testTarget(
            name: "SecurityManagerTests", dependencies: ["SecurityManager", "ZoroCore"],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(
            name: "ConversationManagerTests",
            dependencies: ["ConversationManager", "SecurityManager", "ZoroCore"], swiftSettings: settings),
        .testTarget(name: "MemoryClientTests", dependencies: ["MemoryClient", "ZoroCore"], swiftSettings: settings),
        .testTarget(name: "PermissionManagerTests", dependencies: ["PermissionManager"], swiftSettings: settings),
        .testTarget(name: "ModelRouterTests", dependencies: ["ModelRouter"], swiftSettings: settings),
    ]
)
