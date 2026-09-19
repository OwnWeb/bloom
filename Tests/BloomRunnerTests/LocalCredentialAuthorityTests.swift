import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

/// Who may push as whom, decided from the pid the kernel reported and the pids the Runner started.
@Suite("Whose GitHub token a local caller gets")
struct LocalCredentialAuthorityTests {
    static func surroundings(
        origin: @escaping @Sendable (Int32) -> SpawnedProcesses.Purpose? = { _ in nil },
        ancestry: @escaping @Sendable (Int32) -> [Int32] = { [$0] },
        panes: [String: Int32] = [:],
        running: [String: String] = [:],
        terminalTurns: [String: String] = [:],
        publishing: Set<String> = []
    ) -> LocalCredentialAuthority.Surroundings {
        .init(origin: { origin($0) }, ancestry: { ancestry($0) }, panePIDs: { panes },
              runningTurn: { running[$0] }, terminalTurn: { terminalTurns[$0] }, isPublishing: { publishing.contains($0) })
    }

    static let peer = LocalCredentialSocket.Peer(pid: 500, uid: 1_002)

    @Test("an agent gets its own chat's turn, and not another chat's")
    func agentsGetTheirOwnChat() async {
        let surroundings = Self.surroundings(origin: { $0 == 500 ? .chat(SessionID("chat-a")) : nil },
                                             running: ["chat-a": "turn-a", "chat-b": "turn-b"])
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", chatID: "chat-a"),
                                                    peer: Self.peer, in: surroundings) == "turn-a")
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", chatID: "chat-b"),
                                                    peer: Self.peer, in: surroundings) == nil,
                "naming somebody else's chat reads, it does not push")
    }

    @Test("a shell gets its own terminal's turn, and only from inside that pane")
    func terminalsGetTheirOwnPane() async {
        let surroundings = Self.surroundings(origin: { _ in .terminalServer }, ancestry: { _ in [500, 210, 200] },
                                             panes: ["mine": 210, "theirs": 310], terminalTurns: ["mine": "turn-m", "theirs": "turn-t"])
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", terminal: "mine"),
                                                    peer: Self.peer, in: surroundings) == "turn-m")
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", terminal: "theirs"),
                                                    peer: Self.peer, in: surroundings) == nil)
    }

    /// A setup script, a service, or anything else on the machine: read-only, whatever it claims.
    @Test("a caller the Runner did not start gets no turn, whatever it names")
    func strangersRead() async {
        let surroundings = Self.surroundings(panes: ["mine": 210], running: ["chat-a": "turn-a"],
                                             terminalTurns: ["mine": "turn-m"])
        for asked in [GitCredentialRoute.Asked(repository: "spatie/bloom", chatID: "chat-a"),
                      GitCredentialRoute.Asked(repository: "spatie/bloom", terminal: "mine"),
                      GitCredentialRoute.Asked(repository: "spatie/bloom")] {
            #expect(await LocalCredentialAuthority.turn(for: asked, peer: Self.peer, in: surroundings) == nil)
        }
    }

    /// The Runner's own push. It needs no pid, because the Runner started the command, and it is
    /// accepted only while that push is running.
    @Test("a named turn holds only while a push runs under it")
    func publishingTurns() async {
        let surroundings = Self.surroundings(publishing: ["turn-p"])
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", turnID: "turn-p"),
                                                    peer: nil, in: surroundings) == "turn-p")
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", turnID: "turn-q"),
                                                    peer: nil, in: surroundings) == nil)
    }

    /// Where the kernel cannot say who connected, nobody pushes. A Mac has no SO_PEERCRED, and a
    /// machine that somehow loses it should read rather than trust a claim.
    @Test("no peer means no write token")
    func withoutAPeer() async {
        let surroundings = Self.surroundings(origin: { _ in .chat(SessionID("chat-a")) }, running: ["chat-a": "turn-a"])
        #expect(await LocalCredentialAuthority.turn(for: .init(repository: "spatie/bloom", chatID: "chat-a"),
                                                    peer: nil, in: surroundings) == nil)
    }
}

/// The socket itself: a request in, an answer out, and the kernel's word on who asked.
@Suite("The credential socket")
struct LocalCredentialSocketTests {
    @Test("a request over the socket is answered, and the caller is named where the kernel says")
    func roundTrip() async throws {
        let directory = try SetupTestSupport.directory("credential-socket")
        let path = directory + "/git-credentials.sock"
        let seen = Mutex<[LocalCredentialSocket.Peer?]>([])
        let socket = try LocalCredentialSocket(path: path) { asked, peer in
            seen.withLock { $0.append(peer) }
            guard asked.repository == "spatie/bloom" else { return nil }
            return GitCredentialRoute.Answer(username: "x-access-token", token: asked.chatID == "chat-a" ? "write" : "read")
        }
        defer { socket.close() }

        let answer = LocalCredentialClient.ask(.init(repository: "spatie/bloom", chatID: "chat-a"), over: path)
        #expect(answer?.token == "write")
        #expect(LocalCredentialClient.ask(.init(repository: "spatie/bloom"), over: path)?.token == "read")
        #expect(LocalCredentialClient.ask(.init(repository: "somebody/else"), over: path) == nil, "an empty answer is no answer")
        #expect(seen.withLock { $0 }.count == 3)
        #if os(Linux)
        // The one thing only the kernel can say, and the whole reason this is not a loopback port.
        #expect(seen.withLock { $0 }.allSatisfy { $0?.pid == getpid() })
        #endif
    }

    @Test("a socket nobody is listening on answers nothing rather than hanging")
    func noListener() throws {
        let directory = try SetupTestSupport.directory("credential-socket-missing")
        #expect(LocalCredentialClient.ask(.init(repository: "spatie/bloom"), over: directory + "/nothing.sock") == nil)
    }
}
