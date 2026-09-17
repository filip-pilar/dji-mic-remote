// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DJIMicRemote",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DJIMicRemote", targets: ["DJIMicRemote"])],
    targets: [
        .executableTarget(name: "DJIMicRemote"),
        .testTarget(name: "DJIMicRemoteTests", dependencies: ["DJIMicRemote"])
    ]
)
