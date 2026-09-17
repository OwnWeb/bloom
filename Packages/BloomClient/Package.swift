// swift-tools-version: 6.2
import PackageDescription

// What a Swift client of Cloud workspaces needs beyond the wire shapes: runbloom.app's client API,
// the connection to one workspace's machine (commands, the event stream, the terminal socket), and
// the decisions a client takes over them (merging a transcript, when to say a machine is waking,
// which list changes deserve a notification). Foundation and BloomProtocol only, so iOS can take
// it as it is. See docs/REMOTE-WORKSPACES.md and the client chapter of docs/WORKSPACE-PROTOCOL.md.
let package = Package(
    name: "BloomClient",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "BloomClient", targets: ["BloomClient"]),
    ],
    dependencies: [
        .package(path: "../BloomProtocol"),
    ],
    targets: [
        .target(
            name: "BloomClient",
            dependencies: [.product(name: "BloomProtocol", package: "BloomProtocol")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomClientTests",
            dependencies: ["BloomClient", .product(name: "BloomProtocol", package: "BloomProtocol")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
