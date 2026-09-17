import BloomCore
import Foundation

/// Moving the machine to another bloom-server release, when runbloom.app asks.
///
/// **Detached, because it restarts the process that started it.** The bootstrap script downloads
/// and verifies the release, moves `/opt/bloom/current`, and restarts the `bloom` service, which
/// ends this process; started as a child it would be killed with its parent halfway through. So it
/// runs in a session of its own, and rolls the symlink back itself if the new version does not
/// answer `/_bloom/health`. See `Tools/bootstrap-machine.sh` and docs/REMOTE-WORKSPACES.md,
/// "Installing and updating bloom-server".
enum MachineUpdate {
    static let script = "/opt/bloom/current/bin/bootstrap-machine.sh"

    static func start(version: String, sha256: String) throws {
        guard version.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RemoteFailure(.invalidValue, "An update needs a release version and its sha256.")
        }
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw RemoteFailure(.unavailable, "This machine has no bootstrap script to update with.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = ["-f", script, "update", version, sha256]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try ProcessLaunch.run(process)
    }
}
