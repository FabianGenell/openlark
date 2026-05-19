// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenLark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenLark", targets: ["OpenLark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "OpenLark",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/OpenLark"
        ),
    ]
)
