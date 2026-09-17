// swift-tools-version: 6.2
import PackageDescription

// The version 1 wire shapes of a Cloud workspace: what a client sends bloom-server, what it
// answers, and what it streams. Plain Foundation and nothing else, because the server and every
// Swift client depend on this rather than on each other. See docs/WORKSPACE-PROTOCOL.md.
let package = Package(
    name: "BloomProtocol",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BloomProtocol", targets: ["BloomProtocol"]),
    ],
    targets: [
        .target(name: "BloomProtocol", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BloomProtocolTests",
            dependencies: ["BloomProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
