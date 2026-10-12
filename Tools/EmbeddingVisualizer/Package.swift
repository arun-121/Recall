// swift-tools-version:5.9
import PackageDescription

// EmbeddingVisualizer: a small command-line tool that reads the chunk embeddings
// from a Recall SQLite database, projects them to 2D with PCA (dependency-free),
// and writes a self-contained interactive HTML scatter plot.
//
// It lives in its own package (depending on the RecallCore library) so the Core
// package stays free of executable targets — which keeps the swift-testing macro
// plugin resolvable under the Command Line Tools toolchain.
//
// Usage:
//   cd Tools/EmbeddingVisualizer
//   swift run EmbeddingVisualizer [path-to-recall.sqlite] [output.html]
let package = Package(
    name: "EmbeddingVisualizer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../../Core")
    ],
    targets: [
        .executableTarget(
            name: "EmbeddingVisualizer",
            dependencies: [
                .product(name: "RecallCore", package: "Core")
            ],
            path: "Sources/EmbeddingVisualizer"
        )
    ]
)
