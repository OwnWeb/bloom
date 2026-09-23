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

    @Test("A database's login goes into its URL, so the client does not connect as this Mac's user")
    func databaseOpensWithLogin() {
        let login = DatabaseLogin(user: "sprite", password: "p@ss:word", database: "there_there")
        let opening = WorkspacePorts.opening(WorkspacePorts.port(5432), localPort: 41_499, login: login)
        guard case .application(let url) = opening else {
            Issue.record("Postgres had no application opening")
            return
        }
        #expect(url.user(percentEncoded: false) == "sprite")
        #expect(url.password(percentEncoded: false) == "p@ss:word")
        #expect(url.host() == "127.0.0.1")
        #expect(url.port == 41_499)
        #expect(url.path() == "/there_there")
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

    // MARK: - What is copied

    @Test("A database copies a connection URL at 127.0.0.1, a web server an http address")
    func copiedAddresses() {
        #expect(WorkspacePorts.address(WorkspacePorts.port(5432), localPort: 41_499) == "postgresql://127.0.0.1:41499")
        #expect(WorkspacePorts.address(WorkspacePorts.port(3306), localPort: 41_306) == "mysql://127.0.0.1:41306")
        #expect(WorkspacePorts.address(WorkspacePorts.port(5173), localPort: 41_173) == "http://localhost:41173")
        #expect(WorkspacePorts.address(WorkspacePorts.port(11211), localPort: 41_211) == "127.0.0.1:41211")
        #expect(WorkspacePorts.address(WorkspacePorts.port(44_321), localPort: 41_321) == "127.0.0.1:41321")
    }

    @Test("Only a database with a scheme can be asked about before it is forwarded")
    func clientProbe() {
        #expect(WorkspacePorts.clientProbe(WorkspacePorts.port(5432)) == URL(string: "postgresql://127.0.0.1"))
        #expect(WorkspacePorts.clientProbe(WorkspacePorts.port(11211)) == nil)
        #expect(WorkspacePorts.clientProbe(WorkspacePorts.port(5173)) == nil)
        #expect(WorkspacePorts.clientProbe(WorkspacePorts.port(5432, reserved: true)) == nil)
    }

    // MARK: - How the popover lays them out

    @Test("Databases lead, the relational one before the cache; web and unnamed ports fold away; Bloom's own are hidden")
    func arrangesTheRealWorkspace() {
        // The list a there-there.app workspace answered with on 24 September 2026.
        let ports = WorkspacePorts.describe([
            (3000, false), (5173, false), (5432, false), (6379, false),
            (8080, true), (8081, true), (8082, false), (8090, false), (41_029, true),
        ])
        let arranged = WorkspacePorts.arrange(ports, forwarded: [])
        #expect(arranged.leading.map(\.number) == [5432, 6379])
        #expect(arranged.more.map(\.number) == [3000, 5173, 8082, 8090])
    }

    @Test("A forwarded port leads whatever it is, so a live address always has a visible row")
    func forwardedPortLeads() {
        let ports = WorkspacePorts.describe([(5173, false), (5432, false), (8082, false)])
        let arranged = WorkspacePorts.arrange(ports, forwarded: [5173, 8082])
        #expect(arranged.leading.map(\.number) == [5432, 5173, 8082])
        #expect(arranged.more.isEmpty)
    }

    @Test("With no database and nothing forwarded, nothing is folded away")
    func nothingFoldedWithoutALead() {
        let ports = WorkspacePorts.describe([(5173, false), (3000, false), (8081, true)])
        let arranged = WorkspacePorts.arrange(ports, forwarded: [])
        #expect(arranged.leading.map(\.number) == [3000, 5173])
        #expect(arranged.more.isEmpty)
    }

    @Test("A reserved port somebody forwarded anyway keeps its row, to show the refusal")
    func forwardedReservedPortShows() {
        let arranged = WorkspacePorts.arrange([WorkspacePorts.port(8081, reserved: true)], forwarded: [8081])
        #expect(arranged.leading.map(\.number) == [8081])
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
