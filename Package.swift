// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseLite",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MouseLite", path: "Sources/MouseLite"),
        .testTarget(name: "MouseLiteTests", dependencies: ["MouseLite"], path: "Tests/MouseLiteTests"),
    ]
)
