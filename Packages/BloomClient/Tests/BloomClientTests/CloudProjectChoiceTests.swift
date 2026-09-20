import Testing
@testable import BloomClient

@Suite("Which project an agent's Bloom Cloud workspace lands in")
struct CloudProjectChoiceTests {
    private let bloom = CloudProjectChoice.Candidate(
        teamID: "t1", teamName: "Spatie", project: RunbloomProject(id: "p1", repository: "spatie/bloom")
    )
    private let flare = CloudProjectChoice.Candidate(
        teamID: "t1", teamName: "Spatie", project: RunbloomProject(id: "p2", repository: "spatie/flare")
    )
    private let bloomElsewhere = CloudProjectChoice.Candidate(
        teamID: "t2", teamName: "Freek", project: RunbloomProject(id: "p3", repository: "spatie/bloom")
    )

    @Test("Standing in a workspace, its own repository is the answer")
    func theCallersRepository() {
        #expect(CloudProjectChoice.choose(named: nil, callerRepository: "spatie/bloom", among: [bloom, flare])
            == .chosen(teamID: "t1", project: bloom.project))
        // GitHub does not care about case and neither does this.
        #expect(CloudProjectChoice.choose(named: nil, callerRepository: "Spatie/Bloom", among: [bloom, flare])
            == .chosen(teamID: "t1", project: bloom.project))
    }

    @Test("Named by id or by repository")
    func named() {
        #expect(CloudProjectChoice.choose(named: "p2", callerRepository: "spatie/bloom", among: [bloom, flare])
            == .chosen(teamID: "t1", project: flare.project))
        #expect(CloudProjectChoice.choose(named: "spatie/flare", callerRepository: nil, among: [bloom, flare])
            == .chosen(teamID: "t1", project: flare.project))
    }

    /// Choosing one would create a machine billed to a team nobody named.
    @Test("The same repository in two teams is refused, not guessed")
    func twoTeamsAreNotGuessed() {
        guard case .refused(let sentence) = CloudProjectChoice.choose(
            named: nil, callerRepository: "spatie/bloom", among: [bloom, bloomElsewhere]
        ) else { Issue.record("expected a refusal"); return }
        #expect(sentence.contains("more than one team"))
        // And the id resolves it.
        #expect(CloudProjectChoice.choose(named: "p3", callerRepository: nil, among: [bloom, bloomElsewhere])
            == .chosen(teamID: "t2", project: bloomElsewhere.project))
    }

    @Test("Nothing to go on, or nothing that matches, says what there is")
    func refusalsNameTheChoices() {
        guard case .refused(let none) = CloudProjectChoice.choose(named: nil, callerRepository: nil, among: [bloom]) else {
            Issue.record("expected a refusal"); return
        }
        #expect(none.contains("spatie/bloom in Spatie"))
        guard case .refused(let missing) = CloudProjectChoice.choose(
            named: nil, callerRepository: "spatie/other", among: [bloom]
        ) else { Issue.record("expected a refusal"); return }
        #expect(missing.contains("No Bloom Cloud project is spatie/other"))
        #expect(CloudProjectChoice.choose(named: nil, callerRepository: "x/y", among: [])
            != .chosen(teamID: "t1", project: bloom.project))
    }
}
