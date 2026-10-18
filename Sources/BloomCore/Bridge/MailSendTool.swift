import Foundation

/// A test email belongs to Bloom's local inbox, even when the current worktree has no app or mail
/// configuration. The server and the selected port are app-wide, so no workspace lookup is needed.
public struct MailSendTool: BridgeToolHandling {
    public struct Endpoint: Sendable {
        public let port: Int

        public init(port: Int) {
            self.port = port
        }
    }

    private let endpoint: @Sendable () async -> Endpoint?

    public init(endpoint: @escaping @Sendable () async -> Endpoint?) {
        self.endpoint = endpoint
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: "mail_send",
        description: """
            Send a plain text test email into Bloom's built-in Incoming mails inbox on this Mac. \
            Use this when asked to send a test email to Bloom or "ourselves", even if the current \
            repository has no app or mail configuration. Bloom uses its currently configured SMTP \
            port. The message is captured locally and is not delivered to an internet recipient. \
            Do not use this tool to send a real email to another person. Incoming mails must be \
            enabled and ready in Bloom Settings. The local message is addressed from \
            bloom-agent@example.test to inbox@example.test.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "subject": .object([
                    "type": .string("string"),
                    "description": .string("Subject shown in Bloom's inbox."),
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string("Plain text body of the test email."),
                ]),
            ]),
            "required": .array([.string("subject"), .string("text")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let current = await endpoint() else {
            return .failure("Enable Incoming mails in Bloom Settings and wait until the inbox is ready before sending a test email.")
        }
        guard MailpitSettings.isValidSMTPPort(current.port, forBundleIdentifier: Bundle.main.bundleIdentifier) else {
            return .failure("Choose a valid SMTP port in Bloom's Incoming mails settings.")
        }
        guard let subject = request.stringParam("subject"), let text = request.stringParam("text") else {
            return .failure("mail_send needs a subject and a plain text body.")
        }
        do {
            let message = try LocalMailSender.Message(subject: subject, text: text)
            try await LocalMailSender.send(message, port: current.port)
            return .json(.object([
                "result": .string("Captured in Bloom's Incoming mails inbox"),
                "subject": .string(message.subject),
                "from": .string(message.from),
                "to": .string(message.to),
            ]))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
