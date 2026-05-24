// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FocusFrame",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FocusFrame", targets: ["FocusFrame"])
    ],
    targets: [
        .executableTarget(
            name: "FocusFrame",
            path: "Sources/FocusFrame",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "FocusFrameTests",
            dependencies: ["FocusFrame"],
            path: "FocusFrameTests"
        ),
    ]
)
