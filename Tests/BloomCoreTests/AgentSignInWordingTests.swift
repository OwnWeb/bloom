import Testing
@testable import BloomCore

struct AgentSignInWordingTests {
    @Test("OpenCode connects a provider, it never signs in to an account")
    func openCodeConnectsAProvider() {
        #expect(AgentSignInWording(kind: .openCode, isConnected: true).button == "Connect another provider…")
        #expect(AgentSignInWording(kind: .openCode, isConnected: false).button == "Connect a provider…")
        #expect(AgentSignInWording(kind: .openCode, isConnected: false).title == "Connect a provider to OpenCode")
    }

    @Test("the other agents keep their account wording")
    func othersSignIn() {
        #expect(AgentSignInWording(kind: .codex, isConnected: true).button == "Sign in with another account…")
        #expect(AgentSignInWording(kind: .claudeCode, isConnected: false).button == "Sign in…")
        #expect(AgentSignInWording(kind: .grok, isConnected: false).title == "Sign in to Grok")
    }
}
