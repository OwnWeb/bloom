import Testing
@testable import BloomRunner

struct RunnerCommandLineTests {
    @Test func anUnknownCommandIsAUsageError() async {
        #expect(await RunnerCommandLine.run(["frobnicate"]) == 64)
    }
}
