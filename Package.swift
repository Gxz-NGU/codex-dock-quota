// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuotaDock",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .target(name: "QuotaShared", path: "Sources/QuotaShared"),
        .executableTarget(
            name: "CodexQuotaDock",
            dependencies: ["QuotaShared"],
            path: "Sources/CodexQuotaDock"
        ),
        .executableTarget(name: "AntigravityQuotaDock", dependencies: ["QuotaShared"], path: "Sources/AntigravityQuotaDock"),
        .testTarget(name: "NativeQuotaTests", dependencies: ["CodexQuotaDock", "AntigravityQuotaDock", "QuotaShared"], path: "Tests/NativeQuotaTests"),
    ]
)
