// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIHub", targets: ["AIHub"]),
        .library(name: "AIHubCore", targets: ["AIHubCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/teunlao/swift-ai-sdk.git", exact: "0.19.0")
    ],
    targets: [
        .target(name: "AIHubCore"),
        .target(name: "AIHubSDK", dependencies: [
            "AIHubCore",
            .product(name: "AISDKProvider", package: "swift-ai-sdk"),
            .product(name: "AISDKProviderUtils", package: "swift-ai-sdk"),
            .product(name: "OpenAIProvider", package: "swift-ai-sdk"),
            .product(name: "AnthropicProvider", package: "swift-ai-sdk"),
            .product(name: "GoogleProvider", package: "swift-ai-sdk")
        ]),
        .executableTarget(name: "AIHub", dependencies: ["AIHubCore", "AIHubSDK"]),
        .testTarget(name: "AIHubCoreTests", dependencies: ["AIHubCore"]),
        .testTarget(name: "AIHubSDKTests", dependencies: ["AIHubSDK", "AIHubCore"]),
        .testTarget(name: "AIHubAppTests", dependencies: ["AIHub", "AIHubCore", "AIHubSDK"])
    ]
)
