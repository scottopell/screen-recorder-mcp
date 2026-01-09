// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenRecorderMCP",
    platforms: [
        .macOS(.v13)  // ScreenCaptureKit requires macOS 12.3+, using 13 for better API support
    ],
    products: [
        .executable(
            name: "screen-recorder-mcp",
            targets: ["ScreenRecorderMCP"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ScreenRecorderMCP",
            path: "Sources/ScreenRecorderMCP"
        ),
        .testTarget(
            name: "ScreenRecorderMCPTests",
            dependencies: ["ScreenRecorderMCP"],
            path: "Tests/ScreenRecorderMCPTests"
        )
    ]
)
