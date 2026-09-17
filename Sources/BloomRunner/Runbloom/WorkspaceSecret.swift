import Foundation
import Synchronization

/// The workspace secret every machine API call carries, which runbloom.app can change under a
/// running machine.
///
/// runbloom.app rotates it whenever somebody loses access to the workspace, so a person removed
/// from it cannot keep a copy that still reports as the machine. It rewrites workspace.json first
/// and then sends `control/secret-rotated`; the old secret stays valid there for two minutes, so
/// reports already on their way still land. The control call can be missed (the machine was
/// between wakes, or the call timed out), which is why a call answered `invalid_workspace_secret`
/// also reads the file again before anything decides the workspace is gone.
public final class WorkspaceSecret: Sendable {
    private let value: Mutex<String>
    private let read: @Sendable () throws -> String

    /// `read` answers the secret as the file holds it now.
    public init(_ initial: String, read: @escaping @Sendable () throws -> String) {
        value = Mutex(initial)
        self.read = read
    }

    /// A secret that never changes, for tests and development.
    public convenience init(fixed: String) {
        self.init(fixed) { fixed }
    }

    public var current: String { value.withLock { $0 } }

    /// Reads the file again. True when that produced a different secret, which is the only case
    /// in which a refused call is worth sending again. A file that cannot be read or is half
    /// written keeps the secret already held.
    @discardableResult
    public func reload() -> Bool {
        guard let fresh = try? read(), !fresh.isEmpty else { return false }
        return value.withLock { held in
            guard held != fresh else { return false }
            held = fresh
            return true
        }
    }
}
