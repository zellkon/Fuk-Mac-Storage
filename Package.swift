// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SafeSpace", platforms: [.macOS(.v13)], products: [
    .library(name: "SafeSpaceCore", targets: ["SafeSpaceCore"]),
    .executable(name: "SafeSpace", targets: ["SafeSpace"])
], targets: [
    .target(name: "SafeSpaceCore"),
    .executableTarget(name: "SafeSpace", dependencies: ["SafeSpaceCore"]),
    .testTarget(name: "SafeSpaceCoreTests", dependencies: ["SafeSpaceCore"])
])
