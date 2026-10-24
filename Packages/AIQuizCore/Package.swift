// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIQuizCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "AIQuizCore", targets: ["AIQuizCore"])
    ],
    dependencies: [
        .package(path: "../LLMKit"),
        // The one third-party dependency SPEC N-5 allows, for reader-mode extraction (F-21).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        // Meta's official Zstandard library, to read current Anki packages (owner-approved 2026-10-23, ADR-021).
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")
    ],
    targets: [
        .target(
            name: "AIQuizCore",
            dependencies: [
                .product(name: "LLMKit", package: "LLMKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "libzstd", package: "zstd")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AIQuizCoreTests",
            dependencies: ["AIQuizCore", .product(name: "LLMKit", package: "LLMKit")],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
