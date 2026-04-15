// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackupBot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BackupBot", targets: ["BackupBot"]),
        .library(name: "BackupBotKit", targets: ["BackupBotKit"]),
    ],
    targets: [
        .executableTarget(
            name: "BackupBot",
            dependencies: ["BackupBotKit"],
            path: "Sources/BackupBot/App",
            exclude: [],
            sources: ["BackupBotApp.swift", "ContentView.swift"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "BackupBotKit",
            dependencies: [],
            path: "Sources/BackupBot",
            exclude: ["App"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "BackupBotTests",
            dependencies: ["BackupBotKit"],
            path: "Tests/BackupBotTests"
        ),
        .testTarget(
            name: "BackupBotUITests",
            dependencies: ["BackupBotKit"],
            path: "Tests/BackupBotUITests"
        ),
    ]
)
