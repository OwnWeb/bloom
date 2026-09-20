import BloomCore
import Testing
@testable import BloomRunner

/// Recognising a local caller by what started it, which is what a sandboxed machine can still read.
@Suite("Which of the Runner's children a caller descends from")
struct SpawnedProcessesTests {
    /// A pretend process tree: pid to parent.
    static func table(_ tree: [Int32: Int32]) -> SpawnedProcesses {
        SpawnedProcesses(parent: { tree[$0] })
    }

    @Test("a caller under an agent is that agent's chat, however deep it sits")
    func underAnAgent() async {
        let processes = Self.table([200: 100, 300: 200, 400: 300, 500: 100])
        await processes.record(pid: 200, for: .chat(SessionID("chat-a")))
        let found = await processes.origin(of: 400)
        #expect(found?.purpose == .chat(SessionID("chat-a")))
        #expect(found?.ancestor == 200)
        #expect(await processes.origin(of: 500) == nil, "a sibling of the agent is nobody's chat")
    }

    @Test("a caller under the tmux server is a terminal, and its pane is in its ancestry")
    func underTmux() async {
        let processes = Self.table([200: 100, 210: 200, 220: 210])
        await processes.record(pid: 200, for: .terminalServer)
        #expect(await processes.origin(of: 220)?.purpose == .terminalServer)
        #expect(await processes.ancestry(of: 220) == [220, 210, 200, 100])
    }

    @Test("a process the Runner has forgotten, or never started, is nobody")
    func forgotten() async {
        let processes = Self.table([200: 100, 300: 200])
        await processes.record(pid: 200, for: .chat(SessionID("chat-a")))
        await processes.forget(pid: 200)
        #expect(await processes.origin(of: 300) == nil)
        await processes.record(pid: 1, for: .chat(SessionID("chat-a")))
        #expect(await processes.origin(of: 1) == nil, "pid 1 is never ours to claim")
    }

    /// A tree that loops, or one deeper than the limit, answers rather than spinning.
    @Test("a walk that cannot end still ends")
    func bounded() async {
        let processes = Self.table([2: 3, 3: 2])
        await processes.record(pid: 99, for: .terminalServer)
        #expect(await processes.origin(of: 2) == nil)
        #expect(await processes.ancestry(of: 2).count <= 64)
    }
}
