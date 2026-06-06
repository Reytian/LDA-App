// swift-tools-version:5.9
// LDACore is the headless Swift core of LDA.app. Swift 5.9 is pinned to avoid
// Swift 6 strict-concurrency friction during the build-out.
import PackageDescription

let package = Package(
    name: "LDACore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LDACore",
            targets: ["LDACore"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        )
    ],
    targets: [
        .target(
            name: "LDACore",
            dependencies: ["ZIPFoundation"],
            path: "Sources/LDACore"
        ),
        .testTarget(
            name: "LDACoreTests",
            dependencies: ["LDACore"],
            path: "Tests/LDACoreTests"
        )
    ]
)
