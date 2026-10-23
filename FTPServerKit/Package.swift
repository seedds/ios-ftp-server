// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FTPServerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FTPServerKit", targets: ["FTPServerKit"]),
        .executable(name: "ftpserverd", targets: ["ftpserverd"]),
    ],
    targets: [
        .target(name: "FTPServerKit"),
        .executableTarget(name: "ftpserverd", dependencies: ["FTPServerKit"]),
        .testTarget(name: "FTPServerKitTests", dependencies: ["FTPServerKit"]),
    ]
)
