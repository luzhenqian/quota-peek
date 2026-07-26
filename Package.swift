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
    dependencies: [
        .package(path: "Vendor/Vortex")
    ],
    targets: [
        .executableTarget(
            name: "QuotaPeek",
            dependencies: [
                .product(name: "Vortex", package: "Vortex")
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
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
