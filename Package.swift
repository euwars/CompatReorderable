// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CompatReorderable",
    platforms: [
        // iOS/iPadOS/Catalyst/visionOS use the system drag-and-drop backend;
        // watchOS uses a SwiftUI gesture backend (it has no drag
        // interactions, matching the native API's reduced scope there). The
        // macOS entry exists so the logic compiles and tests run on a Mac
        // host; the API is inert there.
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
