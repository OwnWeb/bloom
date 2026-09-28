import Foundation

extension Store {
    // MARK: - Oceans

    public func oceans() throws -> [Ocean] {
        try db.query("SELECT * FROM oceans ORDER BY name").map(Self.ocean(from:))
    }

    public func unusedOceanCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM oceans WHERE used_at IS NULL").first?.int("n") ?? 0)
    }

    /// Draws a sea from the whole catalogue, and spends it if nobody has sailed it yet.
    ///
    /// The draw is over every sea, used or not. It used to be over the unused ones only, which
    /// made every new workspace a discovery and filled the map in exactly as many workspaces as
    /// there are seas. Drawn from all of them, the early voyages are nearly all discoveries and
    /// the last few seas take a long time to turn up, which is what makes a full chart worth having.
    ///
    /// Drawn from `OceanCatalog.all` rather than from the table, because the table still holds
    /// the islands the first catalogue shipped with wherever one was claimed, and those are kept
    /// for the map, not to be handed out as a name again.
    ///
    /// The draw and the write happen inside the actor with no suspension between them, so two
    /// workspaces created back to back cannot both discover the same sea. A repeat comes back with
    /// its stored `used_at` untouched, because that date records the discovery and a repeat is not
    /// one. Nil only when the drawn sea has no row, which seeding makes impossible, but a
    /// defensive nil beats a crash in the middle of creating a workspace.
    public func claimOcean(now: Date = Date()) throws -> OceanPick? {
        guard let slug = OceanCatalog.all.randomElement()?.slug,
              let row = try db.query("SELECT * FROM oceans WHERE slug = ?", [.text(slug)]).first else {
            return nil
        }
        var ocean = Self.ocean(from: row)
        guard ocean.usedAt == nil else {
            return OceanPick(
                ocean: ocean, isFirstUse: false, remainingUndiscovered: try unusedOceanCount()
            )
        }
        ocean.usedAt = now
        try db.run(
            "UPDATE oceans SET used_at = ? WHERE slug = ?",
            [.double(now.timeIntervalSince1970), .text(ocean.slug)]
        )
        return OceanPick(
            ocean: ocean, isFirstUse: true, remainingUndiscovered: try unusedOceanCount()
        )
    }
}
