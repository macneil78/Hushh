// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HushCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HushCore", targets: ["HushCore"]),
        .library(name: "HushUI", targets: ["HushUI"]),
    ],
    dependencies: [
        // Pinned exactly: TDLib is bumped deliberately (see README). TDLibFramework must match
        // the version TDLibKit pins.
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.67-42e6a525"),
        .package(url: "https://github.com/Swiftgram/TDLibFramework", exact: "1.8.67-42e6a525"),
        // Animated stickers (Telegram's .tgs files are gzipped Lottie animations).
        .package(url: "https://github.com/airbnb/lottie-spm", exact: "4.6.1"),
    ],
    targets: [
        .target(
            name: "HushCore",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "TDLibFramework", package: "TDLibFramework"),
            ]
        ),
        .target(
            name: "HushUI",
            dependencies: ["HushCore", .product(name: "Lottie", package: "lottie-spm")]
        ),
        .executableTarget(name: "hush-smoke", dependencies: ["HushCore"]),
        .testTarget(
            name: "HushCoreTests",
            dependencies: ["HushCore", "HushUI", .product(name: "TDLibKit", package: "TDLibKit")]
        ),
    ]
)
