// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WYACore",
    products: [
        .library(name: "WYACore", targets: ["WYACore"])
    ],
    targets: [
        .target(name: "WYACore"),
        .testTarget(name: "WYACoreTests", dependencies: ["WYACore"])
    ]
)
