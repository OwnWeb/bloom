import BloomCore
import Testing
@testable import BloomRunner

struct RunnerCommandLineTests {
    @Test func anUnknownCommandIsAUsageError() async {
        #expect(await RunnerCommandLine.run(["frobnicate"]) == 64)
    }
}

/// The shape a Bloom Runner release is tagged with, which two people got wrong in one day.
@Suite("A runner release's tag")
struct RunnerReleaseTagTests {
    @Test("the default tag for a version is the runner shape, not Bloom's own")
    func defaultTag() {
        #expect(RunnerVersion.tag(for: "0.1.0-test.11") == "runner-v0.1.0-test.11")
    }

    @Test("a tag is accepted only for its own version")
    func onlyItsOwnVersion() {
        #expect(RunnerVersion.isTag("runner-v0.1.0-test.11", for: "0.1.0-test.11"))
        // Accepted because Tools/bootstrap-machine.sh accepts it.
        #expect(RunnerVersion.isTag("v0.1.0-test.11", for: "0.1.0-test.11"))
        #expect(!RunnerVersion.isTag("runner-v0.1.0-test.10", for: "0.1.0-test.11"))
        #expect(!RunnerVersion.isTag("main", for: "0.1.0-test.11"))
    }

    /// An update sent with no tag has to resolve to a release that exists. This is the bug: the
    /// default was `v` + version, and no runner release has ever been published under that.
    /// An update sent with no tag has to resolve to a release that exists. This machine has no
    /// bootstrap script, so every call is refused before anything is downloaded; which refusal
    /// comes back is what says whether the tag was accepted.
    @Test("an update with no tag is not refused for its tag")
    func updateWithNoTag() {
        #expect(refusal(tag: nil)?.contains("bootstrap script") == true)
        #expect(refusal(tag: "runner-v0.1.0-test.11")?.contains("bootstrap script") == true)
        #expect(refusal(tag: "runner-v0.1.0-test.10")?.contains("tag has to be") == true)
    }

    /// Item 8 of the review of 19 September 2026: what an update refuses before anything runs. A
    /// version that could name a path, a digest that is not one, a tag for another release, and a
    /// download URL off GitHub's asset hosts all stop here; only the missing script is left.
    @Test("an update refuses a bad version, a bad digest, another release's tag and a foreign URL")
    func updateGuards() {
        let digest = String(repeating: "a", count: 64)
        for version in ["../../etc", "1.2", "1.2.3; rm -rf /", ""] {
            #expect(refusal(version: version, sha256: digest, tag: nil)?.contains("release version") == true, "\(version)")
        }
        for sha in ["", "abc", String(repeating: "A", count: 64), String(repeating: "a", count: 63) + "g"] {
            #expect(refusal(version: "1.2.3", sha256: sha, tag: nil)?.contains("sha256") == true, "\(sha)")
        }
        #expect(refusal(version: "1.2.3", sha256: digest, tag: "v9.9.9")?.contains("tag has to be") == true)
        #expect(refusal(version: "1.2.3", sha256: digest, tag: "runner-v1.2.3", downloadURL: "https://example.com/a")?
            .contains("download_url") == true)
        #expect(refusal(version: "1.2.3", sha256: digest, tag: "runner-v1.2.3",
                        downloadURL: "https://objects.githubusercontent.com/a")?.contains("bootstrap script") == true)
    }

    private func refusal(version: String = "0.1.0-test.11", sha256: String = String(repeating: "a", count: 64),
                         tag: String?, downloadURL: String? = nil) -> String? {
        do {
            try MachineUpdate.start(version: version, sha256: sha256, tag: tag, downloadURL: downloadURL)
            return nil
        } catch let failure as RemoteFailure {
            return failure.message
        } catch {
            return "\(error)"
        }
    }
}
