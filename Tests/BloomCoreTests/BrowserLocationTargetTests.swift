import Testing
@testable import BloomCore

@Suite("Browser location shortcut routing")
struct BrowserLocationTargetTests {
    @Test("the focused browser wins")
    func focusedBrowserWins() {
        let target = BrowserLocationTarget.resolve(
            focused: "right", visible: ["left", "right"], isBrowser: { _ in true }
        )
        #expect(target == "right")
    }

    @Test("a visible browser receives Command-L from another pane")
    func visibleBrowserReceivesCommand() {
        let target = BrowserLocationTarget.resolve(
            focused: "chat", visible: ["chat", "browser"], isBrowser: { $0 == "browser" }
        )
        #expect(target == "browser")
    }

    @Test("Command-L stays untouched outside Browser view")
    func noBrowserLeavesCommandAlone() {
        let target = BrowserLocationTarget.resolve(
            focused: "chat", visible: ["chat", "review"], isBrowser: { _ in false }
        )
        #expect(target == nil)
    }
}
