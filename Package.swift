// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // libghostty 터미널 층. Fine과 같은 엔진·패치·입력 처리를 함께 쓴다(10/31 sm에서 떼어 냄).
        // 그 패키지의 scripts/build-ghostty.sh가 GhosttyKit.xcframework를 만든다.
        .package(path: "../GhosttyTerminal")
    ],
    targets: [
        .executableTarget(
            name: "SpaceManager",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "GhosttyTerminal")
            ],
            path: "Sources/SpaceManager"
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
