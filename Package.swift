// swift-tools-version:5.9
import Foundation
import PackageDescription

// libghostty 터미널 층. Fine과 같은 엔진·패치·입력 처리를 함께 쓴다(10/31 sm에서 떼어 냄).
// 형제 폴더(../GhosttyTerminal)가 있으면 그것을 쓴다 — 엔진을 고치는 이 맥이 그렇다. 없으면(남의 클론)
// 공개 저장소의 릴리스를 쓰고, 그 릴리스에 미리 빌드한 엔진이 들어 있다(Apple Silicon 전용).
let sibling = Context.packageDirectory + "/../GhosttyTerminal/Package.swift"
let terminal: Package.Dependency = FileManager.default.fileExists(atPath: sibling)
    ? .package(path: "../GhosttyTerminal")
    : .package(url: "https://github.com/oesoll/GhosttyTerminal.git", from: "0.2.3")

let package = Package(
    name: "SpaceManager",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [terminal],
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
