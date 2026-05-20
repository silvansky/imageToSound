// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "imageToSound",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "imageToSound", targets: ["imageToSound"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.2"),
        .package(url: "https://github.com/jkandzi/Progress.swift", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "imageToSound",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Progress", package: "Progress.swift"),
            ],
            path: "Sources/imageToSound"
        ),
    ]
)
