// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MessUSDZArchiveKit",
    platforms: [.macOS("15.6")],
    products: [.library(name: "MessUSDZArchiveKit", targets: ["MessUSDZArchiveKit"])],
    targets: [
        .target(name: "MessUSDZArchiveKit"),
        .testTarget(name: "MessUSDZArchiveKitTests", dependencies: ["MessUSDZArchiveKit"]),
    ]
)
