import Foundation
import Testing
@testable import BloomCore

@Suite("What is listening inside a workspace, and where a forward of it lands")
struct WorkspacePortsTests {
    @Test("A known port is named and typed")
    func namesKnownPorts() {
        let ports = WorkspacePorts.describe([(5432, false), (5173, false), (44_321, false)])
        #expect(ports.map(\.number) == [5173, 5432, 44_321])
        #expect(ports[0].name == "Vite")
        #expect(ports[0].kind == .http)
        #expect(ports[1].name == "PostgreSQL")
        #expect(ports[1].kind == .database)
    }

    @Test("An unknown port keeps its number and is still offered")
    func keepsUnknownPorts() {
        let port = WorkspacePorts.describe([(44_321, false)])[0]
        #expect(port.name == nil)
        #expect(port.kind == .other)
        #expect(port.title == "Port 44321")
    }

    @Test("Bloom's own ports are listed and marked, never quietly dropped")
    func marksReservedPorts() {
        let ports = WorkspacePorts.describe([(8080, true), (5432, false)])
        #expect(ports.map(\.reserved) == [false, true])
    }

    @Test("System ports are left out, because nobody asked for sshd")
    func dropsSystemPorts() {
        #expect(WorkspacePorts.describe([(22, false), (80, false), (5432, false)]).map(\.number) == [5432])
    }

    @Test("The same port twice is one row")
    func collapsesDuplicates() {
        // /proc/net/tcp and tcp6 both carry a socket bound to both families.
        #expect(WorkspacePorts.describe([(5432, false), (5432, false)]).count == 1)
    }

    @Test("A workspace's local port is the same on the next launch")
    func localPortIsStable() {
        let first = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5432)
        let again = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5432)
        #expect(first == again)
        #expect(first.first != nil)
    }

    @Test("Two workspaces on the same remote port get different local ports")
    func differentWorkspacesDiffer() {
        let one = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5432).first
        let other = WorkspacePorts.localCandidates(workspace: "ws-def", port: 5432).first
        #expect(one != other)
    }

    @Test("Two ports in one workspace get different local ports")
    func differentPortsDiffer() {
        let database = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5432).first
        let web = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5173).first
        #expect(database != web)
    }

    @Test("Every candidate sits below the range macOS hands out for outgoing sockets")
    func candidatesStayInRange() {
        for workspace in ["a", "b", "workspace-with-a-longer-id", ""] {
            for port in [1024, 5432, 65_535] {
                let candidates = WorkspacePorts.localCandidates(workspace: workspace, port: port)
                #expect(candidates.count == 32)
                #expect(Set(candidates).count == 32, "a candidate was offered twice")
                for candidate in candidates {
                    #expect(candidate >= WorkspacePorts.lowestLocal)
                    #expect(candidate < WorkspacePorts.lowestLocal + WorkspacePorts.localRange)
                    // Otherwise a browser's next outgoing socket can take a forward's saved port.
                    #expect(candidate < WorkspacePorts.firstEphemeral)
                }
            }
        }
    }

    // MARK: - What a forward can be opened with

    @Test("A web server opens in the browser pane, at localhost")
    func webServerOpensInTheBrowser() {
        let vite = WorkspacePorts.port(5173)
        #expect(WorkspacePorts.opening(vite, localPort: 41_734) == .browser(URL(string: "http://localhost:41734")!))
    }

    @Test("A database is handed on by its clients' scheme, at 127.0.0.1 so MySQL does not reach for a socket")
    func databaseOpensInAnApplication() {
        #expect(WorkspacePorts.opening(WorkspacePorts.port(5432), localPort: 43_217) == .application(URL(string: "postgresql://127.0.0.1:43217")!))
        #expect(WorkspacePorts.opening(WorkspacePorts.port(3306), localPort: 43_306) == .application(URL(string: "mysql://127.0.0.1:43306")!))
        #expect(WorkspacePorts.opening(WorkspacePorts.port(6379), localPort: 43_379) == .application(URL(string: "redis://127.0.0.1:43379")!))
        #expect(WorkspacePorts.opening(WorkspacePorts.port(27017), localPort: 43_017) == .application(URL(string: "mongodb://127.0.0.1:43017")!))
    }

    @Test("A database no application registers a scheme for has nothing to open")
    func memcachedHasNoOpening() {
        #expect(WorkspacePorts.opening(WorkspacePorts.port(11211), localPort: 43_211) == nil)
    }

    @Test("An unnamed port is only ever copied, never guessed at")
    func unknownPortHasNoOpening() {
        #expect(WorkspacePorts.opening(WorkspacePorts.port(44_321), localPort: 41_000) == nil)
    }

    @Test("Bloom's own port is never opened, even if a row for it had a local port")
    func reservedPortHasNoOpening() {
        #expect(WorkspacePorts.opening(WorkspacePorts.port(8080, reserved: true), localPort: 41_000) == nil)
    }

    @Test("describe and port agree, so a manually forwarded port is named like a listed one")
    func manualPortIsNamed() {
        #expect(WorkspacePorts.describe([(5432, false)]) == [WorkspacePorts.port(5432)])
        #expect(WorkspacePorts.port(5432).scheme == "postgresql")
    }

    @Test("A forwarded page's address is known by its host and port, and the preview's never is")
    func forwardedPageAddress() {
        #expect(WorkspacePorts.forwardedLocalPort(in: "http://localhost:41734") == 41_734)
        #expect(WorkspacePorts.forwardedLocalPort(in: "http://127.0.0.1:41734/orders?page=2") == 41_734)
        // The preview, which is the machine's host over HTTPS.
        #expect(WorkspacePorts.forwardedLocalPort(in: "https://m-01k5.runbloom.app/_bloom/preview/enter?token=x") == nil)
        // A dev server of this Mac's own, which is not a forward.
        #expect(WorkspacePorts.forwardedLocalPort(in: "http://localhost:3000") == nil)
        #expect(WorkspacePorts.forwardedLocalPort(in: "") == nil)
    }

    @Test("Every opening a forward is given is an address a Cloud tab recognises as a forward")
    func openingsAreRecognised() {
        let local = WorkspacePorts.localCandidates(workspace: "ws-abc", port: 5173)[0]
        guard case .browser(let url) = WorkspacePorts.opening(WorkspacePorts.port(5173), localPort: local) else {
            Issue.record("Vite had no browser opening")
            return
        }
        #expect(WorkspacePorts.forwardedLocalPort(in: url.absoluteString) == local)
    }
}
