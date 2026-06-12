// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CompatReorderable",
    platforms: [
        // iOS/iPadOS/Catalyst/visionOS use the system drag-and-drop backend;
        // watchOS and macOS use a SwiftUI gesture backend (they have no drag
        // interactions — for watchOS that matches the native API's reduced
        // scope there).
        .iOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CompatReorderable", targets: ["CompatReorderable"]),
    ],
    targets: [
        .target(
            name: "CompatReorderable",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CompatReorderableTests",
            dependencies: ["CompatReorderable"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
