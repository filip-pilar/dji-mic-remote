// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "DJIMicRemote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DJIMicRemote", targets: ["DJIMicRemote"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "b68f484789d81fda21efbf81e2ca9fcfd9dc22aa", traits: [])],
    targets: [
        .executableTarget(name: "DJIMicRemote", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], resources: [.copy("Resources")]),
        .testTarget(name: "DJIMicRemoteTests", dependencies: ["DJIMicRemote"])
    ],
    swiftLanguageModes: [.v5]
)
