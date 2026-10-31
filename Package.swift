// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // libghostty. scripts/build-ghostty.sh가 Frameworks/에 만든다.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "SpaceManager",
            dependencies: [
                "GhosttyKit"
            ],
            path: "Sources/SpaceManager",
            exclude: ["Terminal/Ghostty/LICENSE-ghostty"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "sm",
            path: "Sources/sm"
        ),
        .testTarget(
            name: "SpaceManagerTests",
            dependencies: ["SpaceManager"],
            path: "Tests/SpaceManagerTests"
        )
    ]
)
