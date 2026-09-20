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

    @Test("a Cloud workspace has what it is handed and nothing else")
    func cloudIsWhatItIsGiven() {
        let today = WorkspaceCapabilities.cloud()
        for capability in WorkspaceCapabilities.Capability.allCases {
            #expect(!today.has(capability), "a Cloud workspace has \(capability.rawValue) without being given it")
        }
        let merging = WorkspaceCapabilities.cloud(managePullRequest: true, preview: true)
        #expect(merging.has(.managePullRequest))
        #expect(merging.has(.preview))
        #expect(!merging.has(.editFiles))
        #expect(!merging.has(.reviewComments))
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
