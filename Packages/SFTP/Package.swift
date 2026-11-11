// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SFTP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SFTP", targets: ["SFTP"]),
    ],
    targets: [
        .target(name: "SFTP"),
        .testTarget(name: "SFTPTests", dependencies: ["SFTP"]),
        .executableTarget(name: "sftp-bench", dependencies: ["SFTP"]),
    ]
)
