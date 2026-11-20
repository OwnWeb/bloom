import Testing
@testable import BloomCore

struct AgentSignInWordingTests {
    @Test("OpenCode connects a provider, it never signs in to an account")
    func openCodeConnectsAProvider() {
        #expect(AgentSignInWording(kind: .openCode, isConnected: true).button == "Connect another provider…")
        #expect(AgentSignInWording(kind: .openCode, isConnected: false).button == "Connect a provider…")
        #expect(AgentSignInWording(kind: .openCode).title == "Connect a provider to OpenCode")
        // A stock install is connected, and there is no account for that sheet to change.
        #expect(AgentSignInWording(kind: .openCode).switchingNote == nil)
        #expect(!AgentSignInWording(kind: .openCode).intro.contains("sign in"))
    }

    @Test("the other agents keep their account wording")
    func othersSignIn() {
        #expect(AgentSignInWording(kind: .codex, isConnected: true).button == "Sign in with another account…")
        #expect(AgentSignInWording(kind: .claudeCode, isConnected: false).button == "Sign in…")
        #expect(AgentSignInWording(kind: .grok).title == "Sign in to Grok")
        #expect(AgentSignInWording(kind: .codex).switchingNote == "This changes the account used by Codex on this Mac.")
    }
}
