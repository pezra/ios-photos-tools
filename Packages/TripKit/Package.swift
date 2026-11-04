// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TripKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TripKit", targets: ["TripKit"]),
    ],
    targets: [
        .target(name: "TripKit"),
        .testTarget(name: "TripKitTests", dependencies: ["TripKit"]),
    ]
)
