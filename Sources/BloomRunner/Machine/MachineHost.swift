import BloomCore
import Foundation

/// The provider, from inside the machine: holding it awake, letting it sleep, and reading what it
/// bills for.
///
/// **The only provider-specific surface in Bloom Runner.** Creating, waking, deleting and naming
/// machines are runbloom.app's; inside, the server needs exactly these. Sprites are the first
/// implementation, and a second provider is another type conforming to this, with no word of
/// either reaching anything a person reads. See docs/REMOTE-WORKSPACES.md, "Where the code goes".
public protocol MachineHost: Sendable {
    /// Keeps the machine awake for at least this long from now. Called again before it runs out.
    func hold(for duration: Duration) async throws
    /// Lets the machine sleep. On Sprites it pauses almost at once, so everything that must reach
    /// anybody has to have gone before this is called.
    func release() async throws
    /// What the provider bills for, measured from inside, or nil where it cannot be read.
    func usageSample() -> MachineUsageReading?
}

/// No provider: for development on a Mac and for tests. Holding does nothing and nothing sleeps.
public struct LocalMachineHost: MachineHost {
    public init() {}
    public func hold(for duration: Duration) async throws {}
    public func release() async throws {}
    public func usageSample() -> MachineUsageReading? { LinuxProcReader.sample() }
}
