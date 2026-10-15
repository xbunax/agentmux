// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentMuxTransportProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SSHProbe",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: ".",
            exclude: ["src", "scripts", "docs", "build", "target", "dist", "ios/AgentMux.xcodeproj"],
            sources: ["ios/Sources/SSHTransport.swift", "tests/SSHProbe.swift"]
        )
    ]
)
