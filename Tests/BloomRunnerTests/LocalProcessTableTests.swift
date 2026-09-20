import BloomCore
import Foundation
import Testing
@testable import BloomRunner

/// Reading who is on the other end of a loopback connection, from a `/proc` laid out by hand, so
/// the walk is tested on any machine; one test at the foot reads the real one on Linux.
@Suite("Who a local caller is")
struct LocalProcessTableTests {
    /// A fake `/proc`: `processes` maps pid to (parent, environment, socket inode it holds).
    static func table(runner: Int32 = 100, callerPort: Int = 40_000, inode: String = "777",
                      processes: [Int32: (Int32, [String: String], String?)]) throws -> LocalProcessTable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proc-\(UUID().uuidString)").path
        let files = FileManager.default
        try files.createDirectory(atPath: root + "/net", withIntermediateDirectories: true)
        let port = String(format: "%04X", callerPort)
        let tcp = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F91 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555 1 0 100 0 0 10 0
           1: 0100007F:\(port) 0100007F:1F91 01 00000000:00000000 00:00000000 00000000  1000        0 \(inode) 1 0 20 4 30 10 -1

        """
        try tcp.write(toFile: root + "/net/tcp", atomically: true, encoding: .utf8)
        for (pid, (parent, environment, socket)) in processes {
            let directory = root + "/\(pid)"
            try files.createDirectory(atPath: directory + "/fd", withIntermediateDirectories: true)
            try "\(pid) (some (odd) name) S \(parent) 1 1 0".write(toFile: directory + "/stat", atomically: true, encoding: .utf8)
            let environ = environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\0") + "\0"
            try environ.write(toFile: directory + "/environ", atomically: true, encoding: .utf8)
            if let socket { try files.createSymbolicLink(atPath: directory + "/fd/3", withDestinationPath: "socket:[\(socket)]") }
        }
        return LocalProcessTable(root: root, runner: runner)
    }

    @Test("git under an agent is that agent's chat")
    func anAgentsGit() throws {
        let table = try Self.table(processes: [
            200: (100, ["BLOOM_CHAT_ID": "chat-a"], nil),   // the agent the Runner started
            300: (200, ["BLOOM_CHAT_ID": "chat-b"], nil),   // a shell under it, lying about its chat
            400: (300, [:], "777"),                         // git's credential helper, the caller
        ])
        #expect(table.origin(ofLocalPort: 40_000, terminalServer: nil) == LocalOrigin(chatID: SessionID("chat-a")),
                "read from what the Runner started, never from what a descendant says")
    }

    @Test("a shell in a terminal is that terminal, and only under the Runner's own tmux server")
    func aTerminalsShell() throws {
        let processes: [Int32: (Int32, [String: String], String?)] = [
            200: (100, [:], nil),                              // tmux server
            210: (200, ["BLOOM_TERMINAL": "mine"], nil),       // the pane's shell
            220: (210, [:], "777"),                            // git
        ]
        #expect(try Self.table(processes: processes).origin(ofLocalPort: 40_000, terminalServer: 200) == LocalOrigin(terminal: "mine"))
        #expect(try Self.table(processes: processes).origin(ofLocalPort: 40_000, terminalServer: 999) == LocalOrigin(),
                "a setup script that sets BLOOM_TERMINAL for its child is not a terminal")
    }

    @Test("a publishing command carries its turn, and a process outside the Runner is nobody")
    func publishingAndStrangers() throws {
        let publishing = try Self.table(processes: [200: (100, ["BLOOM_TURN_ID": "turn-1"], nil), 300: (200, [:], "777")])
        #expect(publishing.origin(ofLocalPort: 40_000, terminalServer: nil) == LocalOrigin(turnID: "turn-1"))
        let stranger = try Self.table(processes: [200: (1, ["BLOOM_CHAT_ID": "chat-a"], nil), 300: (200, [:], "777")])
        #expect(stranger.origin(ofLocalPort: 40_000, terminalServer: nil) == nil)
        let nobodyOnThatPort = try Self.table(processes: [200: (100, ["BLOOM_CHAT_ID": "chat-a"], "777")])
        #expect(nobodyOnThatPort.origin(ofLocalPort: 40_001, terminalServer: nil) == nil)
    }

    #if os(Linux)
    /// The one read of the real table: a connection this test opens is held by this test.
    @Test("on Linux, the process holding a loopback socket is found")
    func findsTheRealHolder() throws {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
        listen(listener, 1)
        var bound = sockaddr_in()
        var boundLength = length
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &boundLength) } }
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) } }
        #expect(connected == 0)
        var local = sockaddr_in()
        var localLength = length
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(client, $0, &localLength) } }
        let port = Int(UInt16(bigEndian: local.sin_port))
        #expect(LocalProcessTable().pid(holdingLocalPort: port) == getpid())
    }
    #endif
}
