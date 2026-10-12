// swift-tools-version:5.9
import PackageDescription

// RecallCore: all domain logic (storage, extraction, embeddings, search,
// indexing). Kept in its own package WITHOUT any executable target so that the
// Command Line Tools toolchain can resolve the swift-testing macro plugin when
// running `swift test`. (An executable target in the same package graph breaks
// swift-testing macro resolution under CLT-only toolchains.)
//
// Deployment target is macOS 13 here because the swift-testing macros bundled
// with the Command Line Tools resolve correctly at v13.
let package = Package(
    name: "RecallCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RecallCore", targets: ["RecallCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "RecallCore",
            dependencies: ["CSQLite"],
            path: "Sources/RecallCore"
        ),
        .testTarget(
            name: "RecallCoreTests",
            dependencies: ["RecallCore"],
            path: "Tests/RecallCoreTests"
        )
    ]
)
