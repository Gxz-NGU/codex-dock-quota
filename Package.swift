// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuotaDock",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaDock",
            path: "Sources/CodexQuotaDock"
        ),
        .testTarget(name: "NativeQuotaTests", dependencies: ["CodexQuotaDock"], path: "Tests/NativeQuotaTests"),
    ]
)
