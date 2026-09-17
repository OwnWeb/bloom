import Foundation

/// Which bloom-server this is, as `/_bloom/health` and every summary report it.
///
/// Stamped by the release packaging through `BLOOM_SERVER_VERSION` at build time would need a
/// generated file; reading it from the environment the service starts with, falling back to the
/// directory the binary was unpacked into (`/opt/bloom/<version>/bin`), needs nothing generated
/// and is what `bootstrap-machine.sh` lays out anyway.
public enum ServerVersion {
    public static var current: String {
        if let stated = ProcessInfo.processInfo.environment["BLOOM_SERVER_VERSION"], !stated.isEmpty { return stated }
        let binary = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let versionDirectory = binary.deletingLastPathComponent().deletingLastPathComponent()
        if versionDirectory.deletingLastPathComponent().path == "/opt/bloom" { return versionDirectory.lastPathComponent }
        return "development"
    }
}
