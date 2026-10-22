// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIQuizCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "AIQuizCore", targets: ["AIQuizCore"])
    ],
    dependencies: [
        .package(path: "../LLMKit")
    ],
    targets: [
        .target(
            name: "AIQuizCore",
            dependencies: [.product(name: "LLMKit", package: "LLMKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AIQuizCoreTests",
            dependencies: ["AIQuizCore", .product(name: "LLMKit", package: "LLMKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
