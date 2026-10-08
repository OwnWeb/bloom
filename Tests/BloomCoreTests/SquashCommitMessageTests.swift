import Foundation
import Testing
@testable import BloomCore

@Suite("Squash commit message")
struct SquashCommitMessageTests {
    private let pullRequest = PullRequest(number: 12, title: "Ship it", url: "", state: "OPEN")

    @Test("the proposal is GitHub's own subject, and leaving it adds nothing to the turn")
    func untouched() {
        let proposed = SquashCommitMessage.proposed(for: pullRequest)
        #expect(proposed == SquashCommitMessage(subject: "Ship it (#12)"))
        #expect(proposed.instruction(proposed: proposed) == nil)
        #expect(SquashCommitMessage(subject: "  ").instruction(proposed: proposed) == nil)
    }

    @Test("an edited subject alone is passed as --subject, leaving GitHub's body")
    func subjectOnly() throws {
        let asked = try #require(SquashCommitMessage(subject: "Ship the thing").instruction(proposed: .proposed(for: pullRequest)))
        #expect(asked.contains("`--subject`"))
        #expect(!asked.contains("--body"))
        #expect(asked.contains("```\nShip the thing\n```"))
    }

    @Test("a body is passed as --body, fenced so its own backticks cannot close the block")
    func withBody() throws {
        let message = SquashCommitMessage(subject: "Ship it (#12)", body: "Uses ```code``` here")
        let asked = try #require(message.instruction(proposed: .proposed(for: pullRequest)))
        #expect(asked.contains("`--body`"))
        #expect(asked.contains("````\nUses ```code``` here\n````"))
    }
}
