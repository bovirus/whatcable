// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhatCable",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhatCable", targets: ["WhatCable"]),
        .executable(name: "whatcable-cli", targets: ["WhatCableCLI"]),
        .library(name: "WhatCableCore", targets: ["WhatCableCore"]),
        .library(name: "WhatCableAppKit", targets: ["WhatCableAppKit"])
    ],
    targets: [
        .target(
            name: "WhatCableCore",
            path: "Sources/WhatCableCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WhatCableNotifications",
            dependencies: ["WhatCableCore"],
            path: "Sources/WhatCableNotifications",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WhatCableDarwinBackend",
            dependencies: ["WhatCableCore"],
            path: "Sources/WhatCableDarwinBackend"
        ),
        .target(
            name: "WhatCableAppKit",
            dependencies: ["WhatCableCore", "WhatCableNotifications"],
            path: "Sources/WhatCableAppKit"
        ),
        .target(
            name: "WhatCablePlugins",
            dependencies: ["WhatCableCore", "WhatCableDarwinBackend", "WhatCableAppKit"],
            path: "Sources/WhatCablePlugins"
        ),
        .executableTarget(
            name: "WhatCable",
            dependencies: ["WhatCableCore", "WhatCableNotifications", "WhatCableDarwinBackend", "WhatCableAppKit", "WhatCablePlugins"],
            path: "Sources/WhatCable",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "WhatCableCLI",
            dependencies: ["WhatCableCore", "WhatCableDarwinBackend", "WhatCableAppKit", "WhatCablePlugins"],
            path: "Sources/WhatCableCLI"
        ),
        .testTarget(
            name: "WhatCableCoreTests",
            dependencies: ["WhatCableCore"],
            path: "Tests/WhatCableCoreTests"
        ),
        .testTarget(
            name: "WhatCableNotificationsTests",
            dependencies: ["WhatCableNotifications", "WhatCableCore"],
            path: "Tests/WhatCableNotificationsTests"
        ),
        .testTarget(
            name: "WhatCableDarwinTests",
            dependencies: ["WhatCableCore", "WhatCable", "WhatCableDarwinBackend"],
            path: "Tests/WhatCableDarwinTests"
        )
    ]
)
