// swift-tools-version: 6.2
import PackageDescription

// Two manifests in one file, because the server half of Bloom builds on Linux and the app half
// cannot: SwiftTerm, Sparkle and the Markdown editor are AppKit, and SwiftPM resolves every
// dependency a manifest names whether or not the product being built uses it. A Linux build
// that declared them would fail before compiling a line of our own. See
// docs/REMOTE-WORKSPACES.md, "Where the code goes".
//
// **Challenged on 18 September 2026 and held.** The objection was that this is about building the
// package rather than one target, and that `swift build --target BloomCore` on Linux gets 532 of
// 534 files through. It does not mean what it looks like: **a missing module aborts at module
// emit**, so the build stops at the first one and never reaches the rest, and **a partial failure
// is not a progress bar.** A census with `swiftc -typecheck` against a real Linux toolchain found
// eight frameworks missing across about twenty files (CoreGraphics, UniformTypeIdentifiers,
// CryptoKit, IOKit, SQLite3, Darwin, CoreServices, Combine), and **the two that no source edit
// can fix are the two this manifest answers**: the `SQLite3` system target below, and `swift-crypto`
// standing in for CryptoKit. The first census said all eight were present, because it used
// `swiftc -parse`, **which is a syntax pass that never resolves an import**.
#if os(Linux)
import Foundation

// The BloomCore tests that run on Linux, by file. An allow-list rather than an exclusion list,
// because most of the suite is about the window and the Mac, and a test added on a Mac should not
// start failing a Linux job its author never thought about. A suite joins this list when the code
// it tests is code the server runs.
let linuxTests: [String] = [
    "AgentRunnerTests.swift",
    "ClaudeModelListTests.swift",
    "CloudWorkspaceStartToolTests.swift",
    "CodexTestSupport.swift",
    "CodexTranslationTests.swift",
    "DiffParserTests.swift",
    "GitTests.swift",
    "MachineMediaShowTests.swift",
    "MachineSandboxTests.swift",
    "PermissionAskTests.swift",
    "PlanApprovalTests.swift",
    "ProcessLaunchTests.swift",
    "ProcessPipeLifetimeTests.swift",
    "RemoteAwakePolicyTests.swift",
    "RemoteUsageMeterTests.swift",
    "RemoteBridgeTests.swift",
    "RemoteCodeSearchTests.swift",
    "RemoteProjectSettingsTests.swift",
    "RemoteQuickPromptsTests.swift",
    "RemoteReviewCacheTests.swift",
    "RemoteReviewLifecycleTests.swift",
    "RemoteDiscardTests.swift",
    "RemoteHistoryTests.swift",
    "RemoteReviewTests.swift",
    "RemoteTerminalsTests.swift",
    "RemoteWorkAtStakeTests.swift",
    "RemoteWorkspaceRuntimeTests.swift",
    "SetupLifecycleTests.swift",
    "ShellCaptureTests.swift",
    "ShellTests.swift",
    "StoreTests.swift",
    "TestSupport.swift",
    "TestWorkloadLimit.swift",
    "WorkspaceFileAccessTests.swift",
    "WorkspaceWriteIsolationTests.swift",
]
let linuxTestDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Tests/BloomCoreTests")
let notOnLinux = try FileManager.default.contentsOfDirectory(atPath: linuxTestDirectory.path)
    .filter { !linuxTests.contains($0) }

let serverDependencies: [Target.Dependency] = [
    "BloomCore",
    .product(name: "BloomProtocol", package: "BloomProtocol"),
    .product(name: "Hummingbird", package: "hummingbird"),
    .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "HTTPTypes", package: "swift-http-types"),
    .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
]

let package = Package(
    name: "Bloom",
    products: [
        .executable(name: "bloom-runner", targets: ["bloom-runner"]),
        .executable(name: "bloom-bridge", targets: ["bloom-bridge"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [
        .package(path: "Packages/BloomProtocol"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        // CryptoKit's API for Linux, where CryptoKit does not exist. The Mac build imports
        // CryptoKit itself and never resolves this.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"])]
        ),
        // The SDK carries SQLite on a Mac; on Linux it is the system library from libsqlite3-dev.
        .systemLibrary(
            name: "SQLite3",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "BloomCore",
            dependencies: [
                "SQLite3",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "BloomProtocol", package: "BloomProtocol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bloom-bridge",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BloomRunner",
            dependencies: ["CZlib"] + serverDependencies + [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "bloom-runner", dependencies: ["BloomRunner"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BloomRunnerTests",
            dependencies: [
                "BloomRunner", "BloomCore", "CZlib", .product(name: "BloomProtocol", package: "BloomProtocol"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            path: "Tests/BloomCoreTests",
            exclude: notOnLinux,
            sources: linuxTests,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
#else

let package = Package(
    name: "Bloom",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bloom", targets: ["Bloom"]),
        .executable(name: "bloom-bridge", targets: ["bloom-bridge"]),
        .executable(name: "bloom-sleep-helper", targets: ["bloom-sleep-helper"]),
        .executable(name: "bloom-runner", targets: ["bloom-runner"]),
        .library(name: "BloomCore", targets: ["BloomCore"]),
    ],
    dependencies: [
        // The Cloud workspace wire shapes, shared by the server and every Swift client.
        .package(path: "Packages/BloomProtocol"),
        // The Mac's half of Cloud workspaces: runbloom.app's API and the connection to a machine,
        // and signing in to a Bloom account. Only the app target names them.
        .package(path: "Packages/BloomClient"),
        .package(path: "Packages/BloomAuthentication"),
        // Bloom Runner's HTTP front, its terminal WebSocket and its client for runbloom.app. The
        // app never links them: only BloomRunner names them, and the app does not depend on it.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        // Native live Markdown editing for workspace notes. Pin the pre-1.0 API we integrate.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.12.0"),
        // The terminal panes. The upper bound is not tidiness: SwiftTerm tags 1.20.0 as a
        // pre-release ("one last before 2.0"), and SwiftPM cannot see that flag because the tag
        // carries no semver pre-release identifier, so a bare `from:` would resolve to it. 1.19.0
        // is what upstream marks as the release, and what upstream says comes next is 2.0 with
        // breaking changes, which this range would have to be opened by hand for anyway.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.19.0" ..< "1.20.0"),
        // The updater. Sparkle ships as a binary XCFramework, so `swift build` links the app
        // against it but copies nothing: `Tools/build.sh` embeds `Sparkle.framework` into
        // `Contents/Frameworks` and adds the rpath that finds it there. See `Tools/build.sh`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(url: "https://github.com/spatie/flare-client-swift.git", from: "1.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            pkgConfig: "zlib"
        ),
        .target(
            name: "BloomCore",
            dependencies: [.product(name: "BloomProtocol", package: "BloomProtocol")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Bloom",
            dependencies: [
                "BloomCore",
                .product(name: "BloomProtocol", package: "BloomProtocol"),
                .product(name: "BloomClient", package: "BloomClient"),
                .product(name: "BloomAuthentication", package: "BloomAuthentication"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Flare", package: "flare-client-swift"),
                .product(name: "FlareCrashReporter", package: "flare-client-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The MCP stdio shim an agent CLI launches, which forwards to the running app over a unix
        // domain socket. Its own file is three lines: `Tools/test-core.sh` mirrors only BloomCore
        // and its tests into the package it runs, so an executable target is invisible to the
        // suite and everything worth testing lives in `BridgeShim` instead.
        .executableTarget(
            name: "bloom-bridge",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The server a Cloud workspace's machine runs, built here as well as on Linux so it can be
        // developed and tested on a Mac. See docs/REMOTE-WORKSPACES.md.
        .target(
            name: "BloomRunner",
            dependencies: [
                "BloomCore", "CZlib",
                .product(name: "BloomProtocol", package: "BloomProtocol"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "bloom-runner", dependencies: ["BloomRunner"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BloomRunnerTests",
            dependencies: [
                "BloomRunner", "BloomCore", "CZlib", .product(name: "BloomProtocol", package: "BloomProtocol"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The privileged daemon that turns the system sleep switch off for a Keep Awake session,
        // which is the only way to hold a Mac open with the lid shut. No dependencies on purpose:
        // it runs as root, so the less of Bloom is inside it the better. See its own file.
        .executableTarget(
            name: "bloom-sleep-helper",
            path: "Sources/bloom-sleep-helper",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
#endif
