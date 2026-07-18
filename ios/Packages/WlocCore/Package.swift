// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WlocCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WlocCore", targets: ["WlocCore"]),
    ],
    targets: [
        .target(name: "WlocCore"),
        .testTarget(name: "WlocCoreTests", dependencies: ["WlocCore"]),
    ],
    swiftLanguageModes: [.v5]
)
