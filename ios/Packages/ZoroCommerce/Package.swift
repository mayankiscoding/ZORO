// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let core: Target.Dependency = .product(name: "ZoroCore", package: "ZoroKit")
let design: Target.Dependency = .product(name: "ZoroDesign", package: "ZoroDesign")

let package = Package(
    name: "ZoroCommerce",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Exposed so `ZoroApp` can set `\.commerceFileUploader`.
        .library(name: "CommerceSupport", targets: ["CommerceSupport"]),
        .library(name: "ShoppingInterface", targets: ["ShoppingInterface"]),
        .library(name: "FinancialInterface", targets: ["FinancialInterface"]),
        .library(name: "InvestmentsFeature", targets: ["InvestmentsFeature"]),
    ],
    dependencies: [
        .package(path: "../ZoroKit"),
        .package(path: "../ZoroDesign"),
    ],
    targets: [
        // Wire helpers shared by the three features (decimal strings, calendar days, multipart
        // bodies, screen phases, figure formatting).
        .target(name: "CommerceSupport", dependencies: [core, design], swiftSettings: settings),
        .target(name: "ShoppingInterface", dependencies: ["CommerceSupport", core, design], swiftSettings: settings),
        .target(name: "FinancialInterface", dependencies: ["CommerceSupport", core, design], swiftSettings: settings),
        .target(name: "InvestmentsFeature", dependencies: ["CommerceSupport", core, design], swiftSettings: settings),

        .testTarget(name: "CommerceSupportTests", dependencies: ["CommerceSupport", core], swiftSettings: settings),
        .testTarget(
            name: "ShoppingInterfaceTests", dependencies: ["ShoppingInterface", "CommerceSupport", core],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(
            name: "FinancialInterfaceTests", dependencies: ["FinancialInterface", "CommerceSupport", core],
            resources: [.copy("Fixtures")], swiftSettings: settings),
        .testTarget(
            name: "InvestmentsFeatureTests", dependencies: ["InvestmentsFeature", "CommerceSupport", core],
            resources: [.copy("Fixtures")], swiftSettings: settings),
    ]
)
