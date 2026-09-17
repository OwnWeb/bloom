import Foundation
import Testing
@testable import BloomCore

/// The line that closes a compaction, and the word that opens one.
///
/// The stream line below is the shape `claude 2.1.274` declares in its own schema: only `trigger`
/// and `pre_tokens` are required and everything under them is optional, which is why so much of
/// this suite is about a line that says less than the full one. The session-file line is the same
/// object in the spelling the CLI writes to `~/.claude/projects`, kept here because a line lifted
/// out of a real session is how anybody will reach for a fixture and it has to decode the same.
@Suite("A conversation being compacted")
struct ContextCompactionTests {
    /// The stream form, which is what Bloom actually reads.
    static let streamLine = #"""
    {"type":"system","subtype":"compact_boundary","session_id":"s1","uuid":"u1",\
    "compact_metadata":{"trigger":"auto","pre_tokens":1000608,"post_tokens":14428,\
    "cumulative_dropped_tokens":986180,"duration_ms":92822}}
    """#.replacingOccurrences(of: "\\\n", with: "")

    /// The same compaction as the session file on disk spells it.
    static let sessionFileLine = #"""
    {"type":"system","subtype":"compact_boundary","content":"Conversation compacted",\
    "level":"info","compactMetadata":{"trigger":"auto","preTokens":1000608,"postTokens":14428,\
    "cumulativeDroppedTokens":986180,"durationMs":92822}}
    """#.replacingOccurrences(of: "\\\n", with: "")

    private func compaction(_ line: String) throws -> ContextCompaction {
        guard case .contextCompacted(let compaction)? = AgentEvent.decode(line: line) else {
            Issue.record("not a compaction boundary")
            throw CancellationError()
        }
        return compaction
    }

    @Test("every figure the stream carries is read")
    func decodesTheStreamForm() throws {
        let compaction = try compaction(Self.streamLine)
        #expect(compaction.trigger == .auto)
        #expect(compaction.preTokens == 1_000_608)
        #expect(compaction.postTokens == 14_428)
        #expect(compaction.cumulativeDroppedTokens == 986_180)
        #expect(compaction.durationMS == 92_822)
        #expect(compaction.uuid == "u1")
        #expect(compaction.sessionID == "s1")
    }

    /// The two spellings are one fact, so a fixture pulled off disk has to answer the same as one
    /// pulled off the wire. Compared whole rather than field by field, because the point is that
    /// nothing differs.
    @Test("the session file's camel case decodes to the same compaction")
    func decodesTheSessionFileForm() throws {
        let stream = try compaction(Self.streamLine)
        let stored = try compaction(Self.sessionFileLine)
        #expect(stored.trigger == stream.trigger)
        #expect(stored.preTokens == stream.preTokens)
        #expect(stored.postTokens == stream.postTokens)
        #expect(stored.cumulativeDroppedTokens == stream.cumulativeDroppedTokens)
        #expect(stored.durationMS == stream.durationMS)
    }

    @Test("a manual /compact is told apart from the window filling up")
    func readsTheTrigger() throws {
        let line = #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":900}}"#
        #expect(try compaction(line).trigger == .manual)
    }

    /// The CLI's own adapter refuses this frame and logs that it is dropping it, so Bloom keeps
    /// the bytes rather than drawing a boundary that could say nothing at all.
    @Test("a boundary with no metadata stays unknown, with its line intact")
    func refusesAFrameWithNoMetadata() throws {
        let line = #"{"type":"system","subtype":"compact_boundary","uuid":"u1"}"#
        guard case .unknown(let raw)? = AgentEvent.decode(line: line) else {
            Issue.record("expected the line to be kept as unknown")
            return
        }
        #expect(String(decoding: raw, as: UTF8.self) == line)
    }

    /// `post_tokens` and `duration_ms` are both optional in the schema, and a row that invented a
    /// figure for either would be worse than one that says less.
    @Test("a line that only carries what is promised still draws")
    func survivesTheMinimalLine() throws {
        let line = #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":512000}}"#
        let compaction = try compaction(line)
        #expect(compaction.postTokens == nil)
        #expect(compaction.durationLabel == nil)
        #expect(compaction.sizeLabel(locale: .init(identifier: "en_GB")) == "512k tokens")
    }

    @Test("the boundary is stored as a system row and belongs in the transcript")
    func isAStoredRow() throws {
        let event = try #require(AgentEvent.decode(line: Self.streamLine))
        #expect(event.kind == .system)
        #expect(event.isTranscriptRow)
        #expect(event.raw == Data(Self.streamLine.utf8))
    }

    /// `TranscriptRowInk` sizes an unmeasured row off this, and a boundary sized as a row that
    /// draws nothing is a boundary the table lays out at no height at all.
    @Test("a stored boundary is recognised by its first bytes, and is known to draw")
    func isSniffedFromTheStoredPayload() {
        let payload = Data(Self.streamLine.utf8)
        #expect(ContextCompaction.isRow(kind: .system, payload: payload))
        #expect(!ContextCompaction.isRow(kind: .assistantText, payload: payload))
        #expect(!TranscriptRowInk.drawsNothing(kind: .system, payload: payload))
    }

    /// Asked of the label the row is about to draw rather than of the raw status, because
    /// `TranscriptModel` capitalises it on the way through.
    @Test(
        "the compacting status is recognised however it is cased",
        arguments: ["compacting", "Compacting", "  COMPACTING "]
    )
    func recognisesTheStatus(label: String) {
        #expect(ContextCompaction.isCompacting(status: label))
    }

    @Test(
        "no other status is mistaken for it",
        arguments: ["Working", "requesting", "Waiting for model", "", "compact"]
    )
    func refusesEveryOtherStatus(label: String) {
        #expect(!ContextCompaction.isCompacting(status: label))
    }

    // MARK: What the row says

    @Test("the sentence names both sizes and the time it took")
    func writesTheSummary() throws {
        let compaction = try compaction(Self.streamLine)
        #expect(compaction.summary(locale: .init(identifier: "en_GB")) == "Compacted 1.0M → 14.4k tokens in 1m 33s")
    }

    @Test(
        "a token count is readable at a glance",
        arguments: [
            (1_000_608, "1.0M"),
            (2_400_000, "2.4M"),
            (986_180, "986k"),
            (100_000, "100k"),
            (14_428, "14.4k"),
            (1000, "1.0k"),
            (999, "999"),
            (0, "0"),
            (-5, "0"),
        ]
    )
    func abbreviatesTokens(count: Int, expected: String) {
        #expect(ContextCompaction.tokens(count, locale: .init(identifier: "en_GB")) == expected)
    }

    /// The decimal separator is a comma on half the machines this runs on, and a figure that is
    /// formatted by hand rather than through the locale is how a Brussels build prints "1.0M"
    /// beside a "1,2 s" everywhere else.
    @Test("the separator follows the locale")
    func followsTheLocale() {
        #expect(ContextCompaction.tokens(14_428, locale: .init(identifier: "nl_BE")) == "14,4k")
    }
}
