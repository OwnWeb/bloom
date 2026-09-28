import Foundation

extension Store {
    // MARK: - Agent quotas

    /// Every allowance any provider has reported and has not yet turned over.
    ///
    /// Expired rows are deleted here rather than filtered, because this is the only place that
    /// reliably runs after a long shutdown and a row for a five hour window that reset last week
    /// is not data, it is litter. Reading is the natural moment: the app was closed across the
    /// reset boundary, it comes back, it asks, and the answer it gets is the truth rather than
    /// last Tuesday's percentage sitting under a reset time in the past.
    ///
    /// A read that deletes is the one thing `StoreChangeHub` warns about, so the delete runs only
    /// when there is genuinely something to delete. Without that guard every reload would write,
    /// every write would wake the reload, and the app would sit warm and busy doing nothing.
    public func quotas(at now: Date = Date()) throws -> [AgentQuota] {
        let cutoff = now.timeIntervalSince1970
        let stale = try db.query(
            "SELECT COUNT(*) AS n FROM agent_quotas WHERE resets_at IS NOT NULL AND resets_at <= ?",
            [.double(cutoff)]
        ).first?.int("n") ?? 0
        if stale > 0 {
            try db.run(
                "DELETE FROM agent_quotas WHERE resets_at IS NOT NULL AND resets_at <= ?",
                [.double(cutoff)]
            )
        }
        return try db.query("SELECT * FROM agent_quotas").compactMap(Self.quota(from:))
    }

    /// Writes what a provider has just said about one or more of its windows.
    ///
    /// `INSERT ... ON CONFLICT` and not `upsert`, and the distinction the whole store turns on
    /// still applies: every column written here was built from the payload that arrived a moment
    /// ago, by the only writer this table has. There is no column on this row belonging to anybody
    /// else, so a whole-value write cannot roll back a write it never knew about.
    ///
    /// The `WHERE` clause is the guard that matters. Two workspaces on the same account both
    /// report the same window, and their turns finish in whatever order the two subprocesses
    /// happen to finish in, so a report that was already stale when it arrived must not overwrite
    /// a fresher one. Comparing `observed_at` makes the write idempotent and order independent.
    public func recordQuotas(_ quotas: [AgentQuota]) throws {
        for quota in quotas {
            let (used, limit, unit) = Self.columns(for: quota.measure)
            try db.run(
                """
                INSERT INTO agent_quotas
                    (provider, window_key, window_label, window_seconds,
                     used, limit_value, unit, resets_at, observed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, window_key) DO UPDATE SET
                    window_label = excluded.window_label,
                    window_seconds = excluded.window_seconds,
                    used = excluded.used,
                    limit_value = excluded.limit_value,
                    unit = excluded.unit,
                    resets_at = excluded.resets_at,
                    observed_at = excluded.observed_at
                WHERE excluded.observed_at >= agent_quotas.observed_at
                """,
                [
                    .text(quota.provider.rawValue),
                    .text(quota.window.key),
                    .text(quota.window.label),
                    quota.window.duration.map { SQLValue.double($0) } ?? .null,
                    used.map { SQLValue.double($0) } ?? .null,
                    limit.map { SQLValue.double($0) } ?? .null,
                    unit.map { SQLValue.text($0) } ?? .null,
                    quota.resetsAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                    .double(quota.observedAt.timeIntervalSince1970),
                ]
            )
        }
    }

    /// The sentinel that says the two numbers are a share rather than a count of something.
    static let fractionUnit = "fraction"

    private static func columns(for measure: QuotaMeasure) -> (Double?, Double?, String?) {
        switch measure {
        case .fraction(let value): (value, 1, fractionUnit)
        case .counted(let used, let limit, let unit): (used, limit, unit)
        case .unknown: (nil, nil, nil)
        }
    }

    private static func quota(from row: Row) -> AgentQuota? {
        guard let provider = row.string("provider").flatMap(AgentKind.init(rawValue:)),
              let key = row.string("window_key") else { return nil }
        let measure: QuotaMeasure
        if let used = row.double("used") {
            let unit = row.string("unit") ?? fractionUnit
            measure = unit == fractionUnit
                ? .fraction(used)
                : .counted(used: used, limit: row.double("limit_value"), unit: unit)
        } else {
            measure = .unknown
        }
        return AgentQuota(
            provider: provider,
            window: QuotaWindow(
                key: key,
                label: row.string("window_label") ?? QuotaWindow.humanised(key),
                duration: row.double("window_seconds")
            ),
            measure: measure,
            resetsAt: row.double("resets_at").map { Date(timeIntervalSince1970: $0) },
            observedAt: row.double("observed_at").map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }
}
