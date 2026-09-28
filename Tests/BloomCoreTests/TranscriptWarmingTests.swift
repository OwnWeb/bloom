import Testing
import Foundation
@testable import BloomCore

@Suite("Preparing rows before a reader reaches them")
struct TranscriptWarmingTests {
    /// Measured rows do not consume the cap. Otherwise every idle pass chooses the same sixty
    /// nearest rows and never prepares any older history.
    @Test("the next batch skips measured rows and advances toward the top")
    func skipsMeasuredRows() {
        let first = TranscriptWarming.nextBatch(in: 0..<150) { $0.isMultiple(of: 2) }
        #expect(first.count == TranscriptWarming.mostRows)
        #expect(first.first == 148)
        #expect(first.last == 30)

        let measured = Set(first)
        let second = TranscriptWarming.nextBatch(in: 0..<150) {
            $0.isMultiple(of: 2) && !measured.contains($0)
        }
        #expect(second.first == 28)
        #expect(second.last == 0)
    }

    @Test("a short band is taken nearest first")
    func aNarrowBandIsWhole() {
        let rows = TranscriptWarming.nextBatch(in: 10..<14) { _ in true }
        #expect(rows == [13, 12, 11, 10])
    }

    @Test("an empty band prepares nothing")
    func anEmptyBandIsNothing() {
        #expect(TranscriptWarming.nextBatch(in: 7..<7) { _ in true }.isEmpty)
    }

    /// A cap of nothing prepares nothing rather than measuring the whole conversation at once.
    @Test("a cap of nothing prepares nothing")
    func noCapPreparesNothing() {
        #expect(TranscriptWarming.nextBatch(in: 0..<500, most: 0) { _ in true }.isEmpty)
    }
}
