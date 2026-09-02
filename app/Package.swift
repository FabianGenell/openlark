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
            path: "Sources/OpenLark",
            // Swift 5 language mode, keeps Swift 6 toolchain features but
            // disables the strict-concurrency errors that fire inconsistently
            // between Xcode 16.0 (CI) and newer toolchains. Revisit when the
            // codebase has been audited for Sendable end-to-end.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
