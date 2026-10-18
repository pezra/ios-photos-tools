// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "S3Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "S3Kit", targets: ["S3Kit"]),
    ],
    targets: [
        .target(name: "S3Kit"),
        .testTarget(name: "S3KitTests", dependencies: ["S3Kit"]),
    ]
)
