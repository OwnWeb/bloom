import BloomCore
import Testing

/// What a workspace can do, which is what views ask instead of what kind it is.
@Suite("Workspace capabilities")
struct WorkspaceCapabilitiesTests {
    @Test("a worktree on this Mac can do everything")
    func local() {
        for capability in WorkspaceCapabilities.Capability.allCases {
            #expect(WorkspaceCapabilities.local.has(capability), "local cannot \(capability.rawValue)")
        }
    }

    @Test("a Cloud workspace never reveals files or keeps this Mac awake")
    func cloudNever() {
        let everything = WorkspaceCapabilities.cloud(
            history: true, revertChanges: true, searchTranscripts: true, preview: true, terminal: true, managePullRequest: true
        )
        #expect(!everything.has(.revealFiles))
        #expect(!everything.has(.keepAwake))
        #expect(everything.has(.history))
        #expect(everything.has(.managePullRequest))
    }

    @Test("what is still being built is off until it is handed in")
    func cloudDefaults() {
        let today = WorkspaceCapabilities.cloud()
        #expect(!today.has(.history))
        #expect(!today.has(.revertChanges))
        #expect(!today.has(.searchTranscripts))
        #expect(!today.has(.managePullRequest))
        #expect(today.has(.terminal))
        #expect(today.has(.preview))
    }

    @Test("every capability says why it is missing, in Cloud workspace words")
    func sentences() {
        for capability in WorkspaceCapabilities.Capability.allCases {
            let sentence = capability.cloudSentence
            #expect(sentence.hasSuffix("."), "\(capability.rawValue) does not end in a full stop")
            #expect(sentence.count > 30)
            let words = sentence.lowercased()
            #expect(!words.contains("sprite") && !words.contains("fly") && !words.contains("runner") && !words.contains("machine"))
        }
    }
}
