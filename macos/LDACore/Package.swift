// swift-tools-version:5.9
// LDACore is the headless Swift core of LDA.app. Swift 5.9 is pinned to avoid
// Swift 6 strict-concurrency friction during the build-out.
import PackageDescription

let package = Package(
    name: "LDACore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LDACore",
            targets: ["LDACore"]
        ),
        .executable(
            name: "lda",
            targets: ["lda"]
        ),
        .executable(
            name: "lda-mcp",
            targets: ["lda-mcp"]
        ),
        .executable(
            name: "LDAApp",
            targets: ["LDAApp"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            .upToNextMajor(from: "1.3.0")
        )
    ],
    targets: [
        // Prebuilt llama.cpp static libraries (Metal embedded) for on-device inference.
        // Built from ~/Developer/llama.cpp via ~/Developer/make_xcframework.sh.
        .binaryTarget(
            name: "Cllama",
            path: "Frameworks/llama.xcframework"
        ),
        .target(
            name: "LDACore",
            dependencies: ["ZIPFoundation", "Cllama"],
            path: "Sources/LDACore",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "LDAUI",
            dependencies: ["LDACore"],
            path: "Sources/LDAUI",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "LDACLI",
            dependencies: [
                "LDACore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/LDACLI"
        ),
        .target(
            name: "LDAMCP",
            dependencies: ["LDACore"],
            path: "Sources/LDAMCP"
        ),
        .executableTarget(
            name: "lda",
            dependencies: ["LDACLI"],
            path: "Sources/lda"
        ),
        .executableTarget(
            name: "lda-mcp",
            dependencies: ["LDAMCP"],
            path: "Sources/lda-mcp"
        ),
        .executableTarget(
            name: "LDAApp",
            dependencies: ["LDAUI"],
            path: "Sources/LDAApp"
        ),
        .testTarget(
            name: "LDACoreTests",
            dependencies: ["LDACore", "LDACLI", "LDAMCP", "LDAUI"],
            path: "Tests/LDACoreTests"
        )
    ]
)
