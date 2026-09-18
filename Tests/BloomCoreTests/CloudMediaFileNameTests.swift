import Testing
@testable import BloomCore

@Suite("What a machine's picture is called on this Mac")
struct CloudMediaFileNameTests {
    @Test("a machine's digest name is kept, extension and all")
    func digestKept() {
        #expect(CloudMediaFileName.of(".bloom/scratch/media/5f1d3c0e9a7b.png") == "5f1d3c0e9a7b.png")
    }

    @Test("a path that would climb out, or hide, becomes a hash with no slash in it")
    func nothingClimbsOut() {
        for path in ["../../Library/Preferences/x.plist", ".bloom/scratch/media/..", ".hidden", "", "a/b c.png"] {
            let name = CloudMediaFileName.of(path)
            #expect(!name.contains("/"))
            #expect(name != ".." && !name.hasPrefix("."))
            #expect(!name.isEmpty)
        }
        #expect(CloudMediaFileName.of("a/b c.png") == CloudMediaFileName.of("a/b c.png"))
    }
}
