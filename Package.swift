// swift-tools-version:5.9
import PackageDescription

// Recall: the native macOS SwiftUI application. It depends on the RecallCore
// package (nested under Core/) which holds all testable domain logic.
//
// Deployment target is macOS 14 because the keyboard-first UI uses `onKeyPress`
// and the two-parameter `onChange`, both introduced in macOS 14.
//
// Build the app:   swift build          (from this directory)
// Run the tests:   cd Core && swift test
let package = Package(
    name: "RecallApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "Core")
    ],
    targets: [
        .executableTarget(
            name: "Recall",
            dependencies: [
                .product(name: "RecallCore", package: "Core")
            ],
            path: "Sources/Recall"
        )
    ]
)
