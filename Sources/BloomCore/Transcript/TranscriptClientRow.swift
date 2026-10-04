import Foundation

/// A platform-neutral reading of one stored event. The host owns provider parsing so a browser
/// and a future phone client do not each learn Claude Code, Codex and Grok wire formats.
///
/// Rows are projected only for the requested page. A long transcript remains in the store until
/// a client asks for its rows, just as the Mac table decodes only what is on screen.
public struct TranscriptClientRow: Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case user
        case assistant
        case thinking
        case tool
        case toolResult
        case permission
        case error
        case notice
        case session
        case plan
        case crew
        case turnEnd
    }

    public let seq: Int
    public let kind: Kind
    public let title: String
    public let text: String
    /// HTML from `MarkdownHTML`, which escapes raw markup and filters unsafe addresses.
    public let html: String?
    public let detail: String
    public let chips: [String]
    public let tint: String
    public let refID: String?
    public let parentToolUseID: String?
    public let requestID: String?
    public let isError: Bool

    private init(
        seq: Int, kind: Kind, title: String = "", text: String = "", html: String? = nil,
        detail: String = "", chips: [String] = [], tint: String = "neutral",
        refID: String? = nil, parentToolUseID: String? = nil, requestID: String? = nil,
        isError: Bool = false
    ) {
        self.seq = seq
        self.kind = kind
        self.title = title
        self.text = text
        self.html = html
        self.detail = detail
        self.chips = chips
        self.tint = tint
        self.refID = refID
        self.parentToolUseID = parentToolUseID
        self.requestID = requestID
        self.isError = isError
    }

    public static func present(_ message: Message, worktree: String = "") -> Self? {
        let raw = String(decoding: message.payload, as: UTF8.self)
        let event = AgentEvent.decode(line: raw)
        let seq = message.seq
        switch message.kind {
        case .user:
            let typed = UserTurnPrompt.text(in: message.payload)
            if let review = ReviewTurn.split(typed) {
                return Self(
                    seq: seq, kind: .user, text: review.message,
                    chips: review.chips.map(\.label)
                )
            }
            let turn = AttachmentTrailer.split(typed)
            let instructions = SentTurn.segments(in: turn.body).compactMap { segment -> String? in
                if case .instructions(let block) = segment { return block.title }
                return nil
            }
            return Self(
                seq: seq, kind: .user, text: SentTurn.withoutInstructions(turn.body),
                chips: turn.paths.map { ($0 as NSString).lastPathComponent } + instructions
            )
        case .assistantText:
            guard case .assistantText(let block)? = event, !block.text.isEmpty else { return nil }
            return Self(
                seq: seq, kind: .assistant, text: block.text,
                html: MarkdownHTML.render(block.text, imagesAsAltText: true).html,
                parentToolUseID: block.parentToolUseID
            )
        case .thinking:
            guard case .thinking(let block)? = event, !block.text.isEmpty else { return nil }
            return Self(seq: seq, kind: .thinking, title: "Thinking", text: block.text,
                        parentToolUseID: block.parentToolUseID)
        case .toolUse:
            guard case .toolUse(let use)? = event else { return nil }
            if let plan = PlanRow.markdown(of: use, resultText: nil) {
                return Self(seq: seq, kind: .plan, title: "Plan", text: plan,
                            html: MarkdownHTML.render(plan, imagesAsAltText: true).html, refID: use.id,
                            parentToolUseID: use.parentToolUseID)
            }
            let presentation = TranscriptPresenter.present(use, worktree: worktree)
            return Self(
                seq: seq, kind: .tool, title: presentation.label,
                detail: presentation.detailLine,
                chips: presentation.chips.map(\.text), tint: presentation.tint.rawValue,
                refID: use.id, parentToolUseID: use.parentToolUseID
            )
        case .toolResult:
            guard case .toolResult(let result)? = event else { return nil }
            return Self(
                seq: seq, kind: .toolResult, title: result.isError ? "Failed" : "Result",
                text: result.text, refID: result.toolUseID,
                parentToolUseID: result.parentToolUseID, isError: result.isError
            )
        case .permissionAsk:
            guard case .permissionAsk(let ask)? = event else { return nil }
            return Self(
                seq: seq, kind: .permission, title: ask.label,
                text: ask.summary.isEmpty ? ask.reason : ask.summary,
                detail: ask.reason, tint: "warning", refID: ask.toolUseID,
                requestID: ask.requestID
            )
        case .error:
            let exit = AgentExit.read(JSONValue.parse(message.payload))
            return Self(seq: seq, kind: .error, title: exit.title,
                        text: exit.summary, detail: exit.advice, tint: "negative", isError: true)
        case .notice:
            guard let sentence = ConversationNotResumed.sentence(fromNote: message.payload)
                ?? RateLimitNotice.sentence(forRateLimitEvent: message.payload) else { return nil }
            return Self(seq: seq, kind: .notice, title: "Notice", text: sentence)
        case .crew:
            guard let crew = CrewMessage.decode(message.payload), !crew.text.isEmpty else { return nil }
            return Self(seq: seq, kind: .crew, title: "Workspace message", text: crew.text,
                        html: MarkdownHTML.render(crew.text, imagesAsAltText: true).html)
        case .result:
            return Self(seq: seq, kind: .turnEnd, title: "Turn finished")
        case .system:
            guard !TranscriptRowInk.drawsNothing(kind: message.kind, payload: message.payload) else { return nil }
            switch event {
            case .initialized(let info):
                return Self(seq: seq, kind: .session, title: "Started with",
                            detail: [info.agentKind.rawValue, info.model, info.permissionMode]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
            case .contextCompacted:
                return Self(seq: seq, kind: .notice, title: "Conversation compacted")
            default:
                return nil
            }
        }
    }
}
