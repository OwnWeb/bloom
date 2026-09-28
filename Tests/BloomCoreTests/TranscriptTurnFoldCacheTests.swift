import Testing
@testable import BloomCore

@Suite("Turn boundary cache")
struct TranscriptTurnFoldCacheTests {
    private func fact(_ seq: Int, _ kind: MessageKind, durationMS: Int? = nil) -> TranscriptTurnFold.Fact {
        TranscriptTurnFold.Fact(seq: seq, kind: kind, durationMS: durationMS)
    }

    @Test("returning to an unchanged transcript reads no facts")
    func unchangedReturn() {
        var cache = TranscriptTurnFoldCache()
        let facts = [fact(0, .user), fact(1, .toolUse), fact(2, .result, durationMS: 1_000)]
        var reads = 0
        let projected = facts.lazy.map { fact in
            reads += 1
            return fact
        }
        let first = cache.resolve(projected)
        #expect(reads > 0)
        reads = 0
        #expect(cache.resolve(projected) == first)
        #expect(reads == 0)
    }

    @Test("new work scans only after the completed turn")
    func appending() {
        var cache = TranscriptTurnFoldCache()
        var facts = [fact(0, .user), fact(1, .toolUse), fact(2, .result)]
        _ = cache.resolve(facts)
        cache.invalidate(row: facts.count)
        facts += [fact(3, .user), fact(4, .toolUse), fact(5, .result)]
        var scanned: [Int] = []
        let returned = cache.resolve(facts.lazy.map { fact in
            scanned.append(fact.seq)
            return fact
        })
        #expect(returned == TranscriptTurnFold.folds(in: facts))
        #expect(!scanned.contains(where: { $0 < 3 }))
    }

    @Test("changing a completed result invalidates its duration")
    func changedResult() throws {
        var cache = TranscriptTurnFoldCache()
        var facts = [fact(0, .user), fact(1, .toolUse), fact(2, .result, durationMS: 1_000)]
        _ = cache.resolve(facts)
        facts[2].durationMS = 2_000
        cache.invalidate(row: 2)
        let turn = try #require(cache.resolve(facts).all.first)
        #expect(turn.durationMS == 2_000)
    }
}
