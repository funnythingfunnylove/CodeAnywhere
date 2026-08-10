// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeAnywhereLinux",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "CodeAnywhereCore", targets: ["CodeAnywhereCore"]),
        .executable(name: "codeanywhere", targets: ["CodeAnywhereCLI"])
    ],
    dependencies: [
        // Keep the Linux toolchain compatible with Swift 6.0.x (the current
        // Debian headless host).  Newer NIO releases require Swift 6.1.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.78.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", exact: "2.15.0")
    ],
    targets: [
        .target(
            name: "CodeAnywhereCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "WebSocketKit", package: "websocket-kit", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/CodeAnywhereCore"
        ),
        .executableTarget(
            name: "CodeAnywhereCLI",
            dependencies: ["CodeAnywhereCore"],
            path: "Sources/CodeAnywhereCLI"
        ),
        .testTarget(
            name: "CodeAnywhereCoreTests",
            dependencies: ["CodeAnywhereCore"],
            path: "Tests/CodeAnywhereCoreTests"
        )
    ]
)
