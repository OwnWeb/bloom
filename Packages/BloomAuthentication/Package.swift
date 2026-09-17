// swift-tools-version: 6.2
import PackageDescription

// Signing in to a Bloom account on runbloom.app: OAuth 2 with PKCE through AppAuth, whose Mac user
// agent is `ASWebAuthenticationSession`, and the tokens in the keychain. Apart from BloomClient
// because it is the one part of a client that needs a window to present from.
let package = Package(
    name: "BloomAuthentication",
    platforms: [.macOS(.v26)],
    products: [.library(name: "BloomAuthentication", targets: ["BloomAuthentication"])],
    dependencies: [
        .package(path: "../BloomClient"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
    ],
    targets: [
        .target(
            name: "BloomAuthentication",
            dependencies: [
                .product(name: "BloomClient", package: "BloomClient"),
                .product(name: "AppAuth", package: "AppAuth-iOS"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
