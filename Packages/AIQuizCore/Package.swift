// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIQuizCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "AIQuizCore", targets: ["AIQuizCore"])
    ],
    targets: [
        .target(
            name: "AIQuizCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AIQuizCoreTests",
            dependencies: ["AIQuizCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
