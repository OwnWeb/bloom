import BloomCore
import Foundation

/// Moving the machine to another Bloom Runner release, when runbloom.app asks.
///
/// **From a URL runbloom.app hands over, when it hands one over.** `spatie/bloom` became private on
/// 19 September 2026, so the release URL the script builds from the tag answers a machine with 404.
/// runbloom.app resolves the asset with its own credential and sends a short-lived signed URL as
/// `download_url`; the machine fetches exactly that, never follows a redirect, never logs it, and
/// still refuses anything whose sha256 is not the one it was given. No GitHub credential reaches
/// the machine. An expired URL fails the update, and runbloom.app sends a fresh one.
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

    /// The hosts GitHub serves a release asset from. A `download_url` anywhere else is refused, and
    /// the script follows no redirect, so it can only ever fetch from one of these.
    static let assetHosts: Set<String> = ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// `download_url` as runbloom.app sent it, if it is an https URL on an asset host. It is a
    /// bearer URL, so the refusal does not repeat it.
    static func checkedDownloadURL(_ text: String?) throws -> String? {
        guard let text else { return nil }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              assetHosts.contains(host), url.user == nil, url.password == nil else {
            throw RemoteFailure(.invalidValue, "An update's download_url has to be an https URL on \(assetHosts.sorted().joined(separator: " or ")).")
        }
        return text
    }

    static func start(version: String, sha256: String, tag: String?, downloadURL: String? = nil) throws {
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
        let downloadURL = try checkedDownloadURL(downloadURL)
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw RemoteFailure(.unavailable, "This machine has no bootstrap script to update with.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = ["-f", script, "update", version, sha256, tag]
        process.standardInput = FileHandle.nullDevice
        // In the environment rather than the arguments: `ps` shows every process's arguments to
        // every user, and this URL is as good as a token until it expires.
        if let downloadURL {
            var environment = ProcessInfo.processInfo.environment
            environment["BLOOM_DOWNLOAD_URL"] = downloadURL
            process.environment = environment
        }
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
