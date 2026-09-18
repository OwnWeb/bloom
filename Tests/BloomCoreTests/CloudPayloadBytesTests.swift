import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

/// A Cloud row's bytes have to answer every row test the way the CLI's own bytes do. See
/// `CloudPayloadBytes`.
@Suite("A Cloud row's payload keeps what the row tests read at the front")
struct CloudPayloadBytesTests {
    private func wire(_ json: String) throws -> WireValue {
        try #require(WireValue.parse(Data(json.utf8)))
    }

    /// The case that was found: sorted, `subtype` went kilobytes in and the init read as noise.
    @Test("an init row with a long command list is still an init row")
    func initSurvives() throws {
        let commands = (0..<200).map { "\"command-\($0)\"" }.joined(separator: ",")
        let value = try wire(
            #"{"type":"system","subtype":"init","cwd":"/w","mcp_servers":[],"slash_commands":["#
                + commands + #"],"session_id":"s"}"#
        )

        let sorted = value.data
        let ours = CloudPayloadBytes.data(value)

        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: sorted))
        #expect(!TranscriptRowInk.drawsNothing(kind: .system, payload: ours))
        #expect(TranscriptRowInk.isSessionStart(kind: .system, payload: ours))
        #expect(ours.starts(with: Data(#"{"type":"system","subtype":"init","#.utf8)))
    }

    @Test("a media_show call with a long caption keeps its name ahead of its input")
    func toolNameBeforeInput() throws {
        let caption = String(repeating: "a long caption ", count: 200)
        let value = try wire(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","#
                + #""name":"mcp__bloom-workspace-bridge__media_show","input":{"path":"shot.png","caption":""#
                + caption + #""}}],"id":"m"}}"#
        )

        #expect(!MediaShowRow.isCall(value.data))
        #expect(MediaShowRow.isCall(CloudPayloadBytes.data(value)))
    }

    @Test("the bytes are JSON that decodes to the same value, escapes and all")
    func roundTrips() throws {
        let tricky = "quote \" slash / back \\ tab \t line \n bell \u{7} accent \u{E9} wave \u{1F30A}"
        let value = WireValue.object([
            "b": .array([.number(1), .number(2.5), .bool(true), .null]),
            "a": .string(tricky),
            "type": .string("x"),
        ])
        let bytes = CloudPayloadBytes.data(value)
        #expect(WireValue.parse(bytes) == value)
        #expect(bytes == CloudPayloadBytes.data(value))
    }
}
