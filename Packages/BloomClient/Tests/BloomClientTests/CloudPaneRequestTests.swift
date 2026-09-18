import Foundation
import Testing
@testable import BloomClient

@Suite("What a machine's request for a pane means")
struct CloudPaneRequestTests {
    private let machine = "m-8fa21c.runbloom.app"

    @Test("No address is the workspace's own app")
    func noAddressIsTheAppItself() {
        #expect(CloudPaneRequest.of(url: nil, machineHost: machine) == .workspaceApp(path: nil))
        #expect(CloudPaneRequest.of(url: "  ", machineHost: machine) == .workspaceApp(path: nil))
    }

    @Test("The machine's own address is the app, at the path it names")
    func itsOwnAddressCarriesThePath() {
        #expect(CloudPaneRequest.of(url: "https://\(machine)/orders?page=2", machineHost: machine)
            == .workspaceApp(path: "/orders?page=2"))
        // The root is the root, not a path of "/".
        #expect(CloudPaneRequest.of(url: "https://\(machine)/", machineHost: machine) == .workspaceApp(path: nil))
        #expect(CloudPaneRequest.of(url: "https://\(machine.uppercased())/orders", machineHost: machine)
            == .workspaceApp(path: "/orders"))
    }

    @Test("Anywhere else is offered rather than opened")
    func somewhereElseIsOffered() {
        #expect(CloudPaneRequest.of(url: "https://example.com/docs", machineHost: machine)
            == .elsewhere(URL(string: "https://example.com/docs")!))
    }

    /// A client that has not fetched a token does not know whose address it is looking at, and
    /// assuming it is the machine's is how a pane opens on a host nobody checked.
    @Test("With no machine host known, a named address is somewhere else")
    func withoutATokenNothingIsTheMachine() {
        #expect(CloudPaneRequest.of(url: "https://\(machine)/orders", machineHost: nil)
            == .elsewhere(URL(string: "https://\(machine)/orders")!))
        // And no address at all is still the workspace's own, which needs no host to know.
        #expect(CloudPaneRequest.of(url: nil, machineHost: nil) == .workspaceApp(path: nil))
    }

    @Test("Only http and https, whatever the machine let through")
    func nothingElseIsABrowserPane() {
        #expect(CloudPaneRequest.of(url: "file:///etc/hosts", machineHost: machine) == .refused)
        #expect(CloudPaneRequest.of(url: "javascript:alert(1)", machineHost: machine) == .refused)
        #expect(CloudPaneRequest.of(url: "bloom://workspace/1", machineHost: machine) == .refused)
        #expect(CloudPaneRequest.of(url: "not a url", machineHost: machine) == .refused)
    }

    @Test("Every case says where it came from")
    func everyCaseIsAccountedFor() {
        #expect(CloudPaneRequest.sentence(.workspaceApp(path: nil), workspace: "Queue retries")
            == "The agent in Queue retries opened its app beside the conversation.")
        #expect(CloudPaneRequest.sentence(.elsewhere(URL(string: "https://example.com")!), workspace: "Queue retries")
            .contains("https://example.com"))
        #expect(CloudPaneRequest.sentence(.refused, workspace: "Queue retries").contains("cannot open"))
    }
}
