// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuotaPeek",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QuotaPeek", targets: ["QuotaPeek"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaPeek",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "QuotaPeekTests",
            dependencies: ["QuotaPeek"]
        )
    ]
)
