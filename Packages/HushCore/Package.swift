// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HushCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HushCore", targets: ["HushCore"]),
        .library(name: "HushUI", targets: ["HushUI"]),
        .library(name: "HushAI", targets: ["HushAI"]),
    ],
    dependencies: [
        // Pinned exactly: TDLib is bumped deliberately (see README). TDLibFramework must match
        // the version TDLibKit pins.
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.67-42e6a525"),
        .package(url: "https://github.com/Swiftgram/TDLibFramework", exact: "1.8.67-42e6a525"),
        // Animated stickers (Telegram's .tgs files are gzipped Lottie animations).
        .package(url: "https://github.com/airbnb/lottie-spm", exact: "4.6.1"),
        // Search by meaning on this Mac: swift-embeddings runs the model on MLTensor (MIT).
        .package(url: "https://github.com/jkrukowski/swift-embeddings", exact: "0.1.1"),
        // Model downloads from Hugging Face, with progress. The version swift-embeddings uses.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "HushCore",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "TDLibFramework", package: "TDLibFramework"),
            ]
        ),
        // Search by meaning, on this Mac. Kept apart so HushCore stays free of the
        // machine-learning dependencies.
        .target(
            name: "HushAI",
            dependencies: [
                "HushCore",
                .product(name: "Embeddings", package: "swift-embeddings"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "HushUI",
            dependencies: ["HushCore", "HushAI", .product(name: "Lottie", package: "lottie-spm")]
        ),
        .executableTarget(name: "hush-smoke", dependencies: ["HushCore"]),
        .testTarget(
            name: "HushCoreTests",
            dependencies: ["HushCore", "HushUI", "HushAI", .product(name: "TDLibKit", package: "TDLibKit")]
        ),
    ]
)
