// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWebSupport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWebSupport",
            targets: ["CmuxWebSupport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWebSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
