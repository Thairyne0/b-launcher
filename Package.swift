// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "BackendLauncher",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BackendLauncher",
            path: "Sources/BackendLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BackendLauncherTests",
            dependencies: ["BackendLauncher"],
            path: "Tests/BackendLauncherTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
