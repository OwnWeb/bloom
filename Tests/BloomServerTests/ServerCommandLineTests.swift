import Testing
@testable import BloomServer

struct ServerCommandLineTests {
    @Test func anUnknownCommandIsAUsageError() async {
        #expect(await ServerCommandLine.run(["frobnicate"]) == 64)
    }
}
