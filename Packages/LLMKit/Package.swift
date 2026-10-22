// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "LLMKit", targets: ["LLMKit"])
    ],
    targets: [
        .target(
            name: "LLMKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
