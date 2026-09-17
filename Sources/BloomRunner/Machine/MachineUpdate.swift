import BloomCore
import Foundation

/// Moving the machine to another Bloom Runner release, when runbloom.app asks.
///
/// **Detached, because it restarts the process that started it.** The bootstrap script downloads
/// and verifies the release, moves `/opt/bloom/current`, and restarts the `bloom` service, which
/// ends this process; started as a child it would be killed with its parent halfway through. So it
/// runs in a session of its own, and rolls the symlink back itself if the new version does not
/// answer `/_bloom/health`. See `Tools/bootstrap-machine.sh` and docs/REMOTE-WORKSPACES.md,
/// "Installing and updating bloom-runner".
enum MachineUpdate {
    static let script = "/opt/bloom/current/bin/bootstrap-machine.sh"
    /// Where the script's output goes. It outlives this process, so nothing here can report a
    /// failed update; the file is how anybody looking at the machine finds out why.
    static let logPath = "/var/tmp/bloom-update.log"

    static func start(version: String, sha256: String, tag: String?) throws {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RemoteFailure(.invalidValue, "An update needs a release version and its sha256.")
        }
        // Only this version's own tag, so a request cannot point the download at another release.
        let tag = tag ?? "v" + version
        guard tag == "v" + version || tag == "runner-v" + version else {
            throw RemoteFailure(.invalidValue, "An update's tag has to be v\(version) or runner-v\(version).")
        }
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw RemoteFailure(.unavailable, "This machine has no bootstrap script to update with.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = ["-f", script, "update", version, sha256, tag]
        process.standardInput = FileHandle.nullDevice
        if !FileManager.default.fileExists(atPath: logPath) {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
        _ = try? log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        try ProcessLaunch.run(process)
    }
}
