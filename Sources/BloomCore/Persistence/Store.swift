import Foundation
import Synchronization

/// All persistence. One actor, one SQLite file. Migrations and domain operations live in
/// the `Store+*.swift` extensions beside this file.
///
/// One rule runs through every table here, and it is worth reading before adding a column or a
/// write. **`upsert` creates a row. `update` modifies one.** An `upsert` writes every column from
/// the value it is handed, so it is correct only when that value was built here and now; hand it
/// something read a few seconds ago and it carries every column back to what it looked like then.
/// `update(workspaceID:)`, `update(repoID:)` and `update(sessionID:)` each read the row inside
/// this actor, apply the change, and write, with no suspension in between, so a write changes
/// what it named and nothing else. Where one writer owns a fixed set of columns, it gets a method
/// that names them: `updateDiffStat`, `touch`, `updateSessionPreferences`, `reorderSessions`,
/// `reorderWorkspaces`, `reorderProjects`, `updateLastReadSeq`.
///
/// Three columns are not writable through `update`'s closure by anybody outside this module at
/// all: `Workspace.state`, `Workspace.setupState` and `Session.state` are `internal(set)`, and the
/// only way to move them is the event methods in `SetupLifecycle`, `SessionLifecycle` and
/// `WorkspaceLifecycle`. Read the head of any of those three for why a state and the work that
/// goes with it have to be one statement. `internal(set)` alone was not enough, and the way round
/// it was this method: `upsert` is public and writes every column, so a fresh value carrying an
/// existing id and any state at all did the job in one compiling line. The initialiser that names
/// those columns is internal too now. See `Workspace.init` in `Models.swift`.
///
/// This is not tidiness. These rows have several writers running at wildly different speeds: a
/// diff stat refresh every six seconds, an archive that takes seconds of disk work before it can
/// say so, an open panel somebody spends a minute in, an agent turn that runs for ten minutes.
/// Whole-value writes from any of them silently rolled the others back, and the damage ranged
/// from a stale count through a project losing its icon to a workspace whose row said it was live
/// after its worktree had been deleted. A column added to a model is picked up by `update`
/// automatically; reach for `upsert` on an existing row and it is reintroduced.
public actor Store {
    // Internal so the domain extensions can share this actor-owned connection.
    let db: SQLiteDatabase
    public nonisolated let path: String

    /// The bundle identifier of the copy the owner actually uses, and the one the dev build gets.
    ///
    /// Written down here because these two strings are the difference between a process that may
    /// open the real database and one that may not. `Tools/dev-build.sh` sets the second, and
    /// `Tools/guard.sh` names the directory that goes with it.
    public static let primaryBundleIdentifier = "be.spatie.bloom"
    public static let devBundleIdentifier = "be.spatie.bloom.dev"

    /// Which Application Support directory a binary with this bundle identifier may use.
    ///
    /// **This is the separation between the dev copy and the owner's data, and it used to be a
    /// paragraph of prose.** The directory was the constant "Bloom", so every process that
    /// reached `defaultPath` without `BLOOM_DB_PATH` opened the real database: the owner's
    /// projects, the real worktree paths, the tmux socket derived from that path. CLAUDE.md and
    /// `Tools/dev-build.sh` both warned about one route into that, `Bloom Dev.app/Contents/MacOS/
    /// Bloom` started by hand, since `LSEnvironment` is applied by LaunchServices and not by a
    /// shell. Nothing warned about the other one, which is `swift run` or `.build/debug/Bloom`,
    /// and neither warning was a control. What was one click away was an archive: a real worktree
    /// removed and its branch offered up for deletion, out of a build nobody thought was pointed
    /// at anything real.
    ///
    /// So it is derived from the binary instead. `LSEnvironment` is belt now rather than the only
    /// strap, and the dev copy is separated whether it is opened or run.
    ///
    /// The dev identifier maps to "Bloom Dev", which is the same directory `Tools/dev-build.sh`
    /// points `BLOOM_DB_PATH` at, so a hand started dev binary lands where it was always meant to
    /// rather than somewhere new. Anything else is a build that is not one of the two: it gets a
    /// directory named after what it is, because a nameless empty database is a mystery and
    /// "Bloom (unbundled)" sitting in Application Support answers itself.
    ///
    /// A pure function of the identifier, rather than of `Bundle.main`, because `Bundle.main`
    /// cannot be varied inside one process and this table is the whole of the rule.
    public static func databaseDirectoryName(forBundleIdentifier identifier: String?) -> String {
        switch identifier {
        case primaryBundleIdentifier: "Bloom"
        case devBundleIdentifier: "Bloom Dev"
        case .some(let other) where !other.isEmpty: "Bloom (\(other))"
        // An executable that is not inside a bundle at all: `swift run`, `.build/debug/Bloom`, or
        // a test host. Nil and empty are the same claim and are treated the same way.
        default: "Bloom (unbundled)"
        }
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = databaseDirectoryName(forBundleIdentifier: Bundle.main.bundleIdentifier)
        return base.appendingPathComponent(name, isDirectory: true)
    }

    private static let migrationOutcome = Mutex<LegacyDatabase.Outcome?>(nil)

    /// What the move out of the old directory decided, for whoever wants to report it. Behind a
    /// lock because `defaultPath` is called by the app on launch and again by an App Intent
    /// performed in the same process, and those two are not ordered.
    public static var lastMigration: LegacyDatabase.Outcome? {
        migrationOutcome.withLock { $0 }
    }

    public static func defaultPath() throws -> String {
        // An override exists so a throwaway instance (a snapshot run, a manual experiment) can be
        // pointed at its own database instead of the one holding the user's real workspaces.
        let environment = ProcessInfo.processInfo.environment
        let override = [environment["BLOOM_DB_PATH"]].compactMap { $0 }
            .first { !$0.isEmpty }
        if let override {
            let directory = (override as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return override
        }

        let directory = defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("bloom.sqlite")

        // Only the real app adopts the database from before the rename, and that is the same rule
        // as the directory above rather than a second one. `adopt` hands back the LEGACY path when
        // the copy fails, on purpose, so that a user who cannot be migrated still runs on their own
        // work; from any other binary that is one more way to end up holding the owner's real rows.
        // A dev copy has never adopted it either, because `BLOOM_DB_PATH` returns above this line.
        guard Bundle.main.bundleIdentifier == primaryBundleIdentifier else {
            return destination.path
        }

        let outcome = LegacyDatabase.adopt(destination: destination)
        migrationOutcome.withLock { $0 = outcome }
        return outcome.path
    }

    public init(path: String) throws {
        self.path = path
        self.db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
        try db.transaction { try Self.seedOceans(db) }
    }

    public static func inMemory() throws -> Store {
        try Store(path: ":memory:")
    }

    /// Every committed write to this database, by table, coalesced. See `StoreObservation.swift`,
    /// and read the two rules on `StoreChangeHub` before writing anything that consumes this.
    ///
    /// `nonisolated` because subscribing is not a database operation and must not queue behind the
    /// writes it wants to hear about. `db` is a `let` of a `Sendable` class, so reading it from
    /// outside the actor is sound.
    ///
    /// The domains are named by the caller rather than filtered afterwards, so a subscriber that
    /// does not care about a table is not woken by it at all. That is not a nicety: `messages` is
    /// written many times a second for the whole of a streaming turn, and it is the one table an
    /// interested-in-everything subscriber would spend all its time on.
    public nonisolated func changes(
        of domains: Set<StoreDomain> = Set(StoreDomain.allCases)
    ) -> StoreChanges {
        StoreChanges(hub: db.changes, interest: domains)
    }

    /// The hub this store's writes land in.
    ///
    /// For the tests, which have to ask one specific database what it published rather than look a
    /// hub up by path. A `:memory:` store has no path to look up, and that it does not share a hub
    /// with the next `:memory:` store is exactly the thing worth pinning.
    nonisolated var changeHub: StoreChangeHub { db.changes }
}
