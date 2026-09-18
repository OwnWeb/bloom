import BloomCore
import Foundation

/// Moving the machine to another Bloom Runner release, when runbloom.app asks.
///
/// **Detached, so it gets as far as the restart.** The bootstrap script downloads and verifies the
/// release, moves `/opt/bloom/current`, and restarts the `bloom` service. Started as a child it
/// would die with this process the moment the download finished; in a session of its own it lives
/// until the restart, which then ends it along with everything else the service started (measured:
/// the provider's restart takes tmux too, `setsid` or not). So it does not watch what happens next,
/// and it does not roll anything back. The start wrapper in `bin/bloom-runner` does that at the next
/// start, and runbloom.app does it through the provider when the machine has not healed. See
/// `Tools/runner-start.sh` and docs/REMOTE-WORKSPACES.md, "Installing and updating bloom-runner".
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
        // Both the default and the check come from `RunnerVersion`, which is the one place the tag
        // shape is stated: this used to default to `v` + version, which is Bloom's own release
        // shape and has never been a runner release, so an update sent without a tag resolved to a
        // download that does not exist.
        let tag = tag ?? RunnerVersion.tag(for: version)
        guard RunnerVersion.isTag(tag, for: version) else {
            throw RemoteFailure(.invalidValue, "An update's tag has to be \(RunnerVersion.tag(for: version)) or v\(version).")
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
