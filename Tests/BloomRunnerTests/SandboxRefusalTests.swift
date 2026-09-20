import Testing
@testable import BloomRunner

/// The sentence somebody reads when a setup script asked for root on a machine that has been used.
@Suite("Reading a setup failure that was really about root")
struct SandboxRefusalTests {
    @Test("a refused sudo names the command, says why, and says what to do")
    func namesTheCommand() throws {
        let advice = try #require(SandboxRefusal.advice(lines: [
            "+ echo installing",
            "+ sudo apt-get install -y libpq-dev",
            "sudo: a password is required",
        ], user: "bloom-agent"))
        #expect(advice.contains("`sudo apt-get install -y libpq-dev` was refused"))
        #expect(advice.contains("runs as bloom-agent"))
        #expect(advice.contains("Replace the machine"))
        #expect(advice.contains(SandboxRefusal.code))
        #expect(advice.hasPrefix("[bloom] "), "clients draw Bloom's own sentences from that prefix")
    }

    @Test("apt's lock and dpkg's refusal read the same way, traced or not")
    func otherShapes() throws {
        let locked = try #require(SandboxRefusal.advice(lines: [
            "apt-get install -y nginx",
            "E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)",
        ], user: "bloom-agent"))
        #expect(locked.contains("`apt-get install -y nginx` was refused"))
        let untraced = try #require(SandboxRefusal.advice(lines: ["dpkg: error: requested operation requires superuser privilege"],
                                                         user: "bloom-agent"))
        #expect(untraced.contains("A command in this script asked for root and was refused"))
    }

    @Test("an ordinary failure gets no advice about root")
    func ordinaryFailures() {
        #expect(SandboxRefusal.advice(lines: ["npm ERR! missing script: build", "exit 1"], user: "bloom-agent") == nil)
        #expect(SandboxRefusal.advice(lines: [], user: "bloom-agent") == nil)
    }
}
