// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PercuscoreCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "PercuscoreCore", targets: ["PercuscoreCore"])],
    targets: [
        .target(name: "PercuscoreCore"),
        .testTarget(name: "PercuscoreCoreTests", dependencies: ["PercuscoreCore"])
    ]
)
