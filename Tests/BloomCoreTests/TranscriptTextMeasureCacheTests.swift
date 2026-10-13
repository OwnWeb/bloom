import Testing
@testable import BloomCore

@Suite("What a run of transcript prose remembers about its own size")
struct TranscriptTextMeasureCacheTests {
    private typealias Cache = TranscriptTextMeasureCache<Double>
    private typealias Key = Cache.Key

    private static func key(_ proposed: Double?, bubble: Bool = false) -> Key {
        Key(proposed: proposed, alignsBubbleInk: bubble)
    }

    /// The bug itself. A list item beside its marker is asked about zero, infinity, a hair and its
    /// own width in every pass, and keeping one answer typeset it on every question. Each of those has to still be there after the others have been asked.
    @Test("every question one layout pass asks keeps its own answer")
    func onePassOfQuestions() {
        var cache = Cache()
        let pass: [Double?] = [nil, 0, 1, .infinity, 617]
        for (index, proposed) in pass.enumerated() {
            cache.store(Double(index), for: Self.key(proposed))
        }
        for _ in 0..<3 {
            for (index, proposed) in pass.enumerated() {
                let answer = cache.value(for: Self.key(proposed))
                #expect(answer == Double(index))
            }
        }
    }

    /// Nothing and infinity are laid out at the same width, and `TranscriptTextMeasure.size`
    /// answers them alike today. The cache is keyed as strictly as the proposal anyway, whatever
    /// `size` does with it, so it can never answer a question it was not asked.
    @Test("no proposal and an infinite one are different questions")
    func nothingIsNotInfinity() {
        var cache = Cache()
        cache.store(1, for: Self.key(nil))
        let infinite = cache.value(for: Self.key(.infinity))
        #expect(infinite == nil)
    }

    /// A bubble's ink offset is part of the answer, so the same width asked with and without it is
    /// two questions.
    @Test("the same width asked for a bubble and for prose are different questions")
    func bubbleIsItsOwnQuestion() {
        var cache = Cache()
        cache.store(1, for: Self.key(456, bubble: true))
        let prose = cache.value(for: Self.key(456))
        #expect(prose == nil)
        let bubble = cache.value(for: Self.key(456, bubble: true))
        #expect(bubble == 1)
    }

    @Test("storing again replaces the answer rather than keeping two")
    func storingAgainReplaces() {
        var cache = Cache()
        cache.store(1, for: Self.key(456))
        cache.store(2, for: Self.key(456))
        #expect(cache.count == 1)
        let answer = cache.value(for: Self.key(456))
        #expect(answer == 2)
    }

    /// A divider drag asks a new width on every frame. The cache stays bounded, and what it drops
    /// is what the drag has moved past, never the questions every pass keeps asking.
    @Test("a drag drops the widths it moved past and keeps the ones asked every pass")
    func dragIsBounded() {
        var cache = Cache()
        let repeated: [Double?] = [nil, 0, 1, .infinity]
        for proposed in repeated { cache.store(-1, for: Self.key(proposed)) }
        for width in stride(from: 600.0, to: 700, by: 4) {
            for proposed in repeated { _ = cache.value(for: Self.key(proposed)) }
            cache.store(width, for: Self.key(width))
            #expect(cache.count <= Cache.capacity)
        }
        for proposed in repeated {
            let answer = cache.value(for: Self.key(proposed))
            #expect(answer == -1)
        }
        let latest = cache.value(for: Self.key(696))
        #expect(latest == 696)
        let first = cache.value(for: Self.key(600))
        #expect(first == nil)
    }

    @Test("new text forgets every answer")
    func removeAll() {
        var cache = Cache()
        cache.store(1, for: Self.key(nil))
        cache.store(2, for: Self.key(456))
        cache.removeAll()
        #expect(cache.count == 0)
        let answer = cache.value(for: Self.key(456))
        #expect(answer == nil)
    }

    // MARK: Which answer goes when the cache is full

    /// Exactly `capacity` answers fit. The next one drops the oldest and only the oldest, and a
    /// question never answered neither takes a slot nor saves anything from eviction.
    @Test("a full cache drops exactly the answer stored first")
    func evictsOldestAtCapacity() {
        var cache = Cache()
        for width in 0..<Cache.capacity { cache.store(Double(width), for: Self.key(Double(width))) }
        #expect(cache.count == Cache.capacity)
        let missing = cache.value(for: Self.key(500))
        #expect(missing == nil)
        #expect(cache.count == Cache.capacity)
        cache.store(99, for: Self.key(99))
        #expect(cache.count == Cache.capacity)
        let oldest = cache.value(for: Self.key(0))
        #expect(oldest == nil)
        for width in 1..<Cache.capacity {
            let kept = cache.value(for: Self.key(Double(width)))
            #expect(kept == Double(width))
        }
        let newest = cache.value(for: Self.key(99))
        #expect(newest == 99)
    }

    /// Being asked again is what keeps an answer. Without the reordering on a hit this is first in,
    /// first out, and a drag would push out the questions every pass repeats.
    @Test("an answer asked for again outlives one stored after it")
    func hitRefreshesRecency() {
        var cache = Cache()
        for width in 0..<Cache.capacity { cache.store(Double(width), for: Self.key(Double(width))) }
        _ = cache.value(for: Self.key(0))
        cache.store(99, for: Self.key(99))
        let refreshed = cache.value(for: Self.key(0))
        #expect(refreshed == 0)
        let dropped = cache.value(for: Self.key(1))
        #expect(dropped == nil)
    }

    @Test("storing an answer again counts as asking for it")
    func storingAgainRefreshesRecency() {
        var cache = Cache()
        for width in 0..<Cache.capacity { cache.store(Double(width), for: Self.key(Double(width))) }
        cache.store(-1, for: Self.key(0))
        cache.store(99, for: Self.key(99))
        let restored = cache.value(for: Self.key(0))
        #expect(restored == -1)
        let dropped = cache.value(for: Self.key(1))
        #expect(dropped == nil)
    }

    /// Least recently used misses every time on a cycle of questions longer than it holds, which
    /// is the bug this cache fixes coming back. These are the passes the views really make: a list
    /// item beside its marker, then a bubble that `CappedWidth` measures at its cap and places at
    /// the width its words used. Both have to fit, with room to spare.
    @Test("the questions real passes repeat all stay answered")
    func realPassesFit() {
        var cache = Cache()
        let listItem: [Key] = [0, .infinity, 1, 617, 616].map { Self.key($0) }
        let bubble: [Key] = [432, 92, 0].map { Self.key($0, bubble: true) }
        for pass in [listItem, bubble] {
            for key in pass { cache.store(1, for: key) }
            for _ in 0..<3 {
                for key in pass {
                    let answer = cache.value(for: key)
                    #expect(answer == 1)
                }
            }
        }
    }

    /// The bound itself: a cycle of exactly `capacity` questions is all answered, every time round.
    @Test("a cycle as long as the capacity never misses")
    func fullCycleNeverMisses() {
        var cache = Cache()
        let cycle = (0..<Cache.capacity).map { Self.key(Double($0)) }
        for key in cycle { cache.store(1, for: key) }
        for _ in 0..<3 {
            for key in cycle {
                let answer = cache.value(for: key)
                #expect(answer == 1)
            }
        }
    }

    // MARK: What counts as the same question

    /// Zero and a hair are laid out at the same width but `TranscriptTextMeasure.size` reports
    /// them differently, so a long word answers differently to each.
    @Test("a proposal of zero and one of a hair are different questions")
    func zeroIsNotAHair() {
        var cache = Cache()
        cache.store(1, for: Self.key(0))
        let hair = cache.value(for: Self.key(1))
        #expect(hair == nil)
        let zero = cache.value(for: Self.key(0))
        #expect(zero == 1)
    }

    @Test("negative zero is the same question as zero")
    func signedZero() {
        var cache = Cache()
        cache.store(1, for: Self.key(0))
        let negative = cache.value(for: Self.key(-0.0))
        #expect(negative == 1)
    }

    /// Widths a fraction of a point apart are asked during a drag on a Retina screen. Keyed on the
    /// exact proposal they are separate answers, and nothing rounds one into the other.
    @Test("widths a fraction of a point apart are different questions")
    func fractionalWidths() {
        var cache = Cache()
        cache.store(1, for: Self.key(616.5))
        let neighbour = cache.value(for: Self.key(617))
        #expect(neighbour == nil)
        let exact = cache.value(for: Self.key(616.5))
        #expect(exact == 1)
    }

    /// SwiftUI never proposes NaN, and NaN equals nothing, so it could never be answered from the
    /// cache. What matters is that it cannot grow the cache past its bound either.
    @Test("a NaN proposal never grows the cache past its capacity")
    func notANumberIsBounded() {
        var cache = Cache()
        for _ in 0..<(Cache.capacity * 2) { cache.store(1, for: Self.key(.nan)) }
        #expect(cache.count == Cache.capacity)
    }

    /// The bubble's ink offset travels with the size, so a hit restores where the ink sat at that
    /// width rather than wherever the last question left it.
    @Test("every part of an answer comes back, not only its size")
    func wholeAnswerReturns() {
        struct Answer: Equatable { var width: Double; var inkOffset: Double }
        typealias AnswerCache = TranscriptTextMeasureCache<Answer>
        var cache = AnswerCache()
        let cap = AnswerCache.Key(proposed: 432, alignsBubbleInk: true)
        let exact = AnswerCache.Key(proposed: 92, alignsBubbleInk: true)
        cache.store(Answer(width: 92, inkOffset: 1.5), for: cap)
        cache.store(Answer(width: 92, inkOffset: 0.5), for: exact)
        let atCap = cache.value(for: cap)
        #expect(atCap == Answer(width: 92, inkOffset: 1.5))
        let placed = cache.value(for: exact)
        #expect(placed == Answer(width: 92, inkOffset: 0.5))
    }
}
