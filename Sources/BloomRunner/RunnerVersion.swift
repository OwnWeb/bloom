import Foundation

/// Which Bloom Runner this is, as `/_bloom/health` and every summary report it.
///
/// Stamped by the release packaging through `BLOOM_RUNNER_VERSION` at build time would need a
/// generated file; reading it from the environment the service starts with, falling back to the
/// directory the binary was unpacked into (`/opt/bloom/<version>/bin`), needs nothing generated
/// and is what `bootstrap-machine.sh` lays out anyway.
public enum RunnerVersion {
    public static var current: String {
        if let stated = ProcessInfo.processInfo.environment["BLOOM_RUNNER_VERSION"], !stated.isEmpty { return stated }
        let binary = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let versionDirectory = binary.deletingLastPathComponent().deletingLastPathComponent()
        if versionDirectory.deletingLastPathComponent().path == "/opt/bloom" { return versionDirectory.lastPathComponent }
        return "development"
    }

    /// The tag a Bloom Runner release is published under, which is the only thing that resolves to
    /// a downloadable tarball.
    ///
    /// **Stated here because two people got it wrong on the same day.** On 18 September 2026 a pin
    /// was written as a bare `0.1.0-test.11` and resolved to nothing, and an hour later this file's
    /// caller was found defaulting to `v0.1.0-test.11`, a tag that has never existed for any runner
    /// release. Both mistakes were made against the same convention by people who knew it, which
    /// means the convention was not written where it was used. It is now written once here.
    ///
    /// The `v` shape is Bloom's own releases, the Mac app, which this is not. Two other places
    /// enforce the same rule in languages that cannot read this one, and they say so where they do
    /// it: `Tools/bootstrap-machine.sh`, which refuses a tag that is not for the version it was
    /// given, and `.github/workflows/release.yml`, which publishes only the runner for a `runner-v`
    /// tag.
    public static func tag(for version: String) -> String { "runner-v" + version }

    /// Whether a tag names this exact version, so a request cannot point a download at another
    /// release. The `v` shape is accepted because the bootstrap script accepts it.
    public static func isTag(_ tag: String, for version: String) -> Bool {
        tag == self.tag(for: version) || tag == "v" + version
    }
}
