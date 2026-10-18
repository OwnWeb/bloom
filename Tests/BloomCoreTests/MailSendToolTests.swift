import Foundation
import Testing
@testable import BloomCore

@Suite("Sending mail to Bloom's inbox")
@MainActor
struct MailSendToolTests {
    @Test("workspace agents can discover and use the local mail tool")
    func listedAndApproved() {
        let toolbox = BridgeToolbox(handlers: [MailSendTool(endpoint: { .init(port: 2525) })])
        #expect(toolbox.tools(for: .workspace).contains { $0.name == "mail_send" })
        #expect(toolbox.tools(for: .owner).contains { $0.name == "mail_send" })
        #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + "mail_send"))
    }

    @Test("an off inbox gives the agent the setting to change")
    func disabled() async throws {
        let store = try makeTestStore("mail-send-disabled")
        let tool = MailSendTool(endpoint: { nil })
        let result = await tool.call(request, as: .owner, store: store)
        #expect(result.isError)
        #expect(result.text.contains("Enable Incoming mails"))
    }

    @Test("subject and addresses cannot inject mail headers")
    func rejectsHeaderInjection() throws {
        #expect(throws: LocalMailSender.Failure.invalidSubject) {
            try LocalMailSender.Message(subject: "Hello\r\nBcc: other@example.test", text: "Test")
        }
        #expect(throws: LocalMailSender.Failure.invalidAddress) {
            try LocalMailSender.Message(subject: "Hello", text: "Test", to: "inbox@example.test\r\nBcc: other@example.test")
        }
    }

    @Test("the tool sends a captured message over loopback SMTP")
    func sendsLocalMessage() async throws {
        let fixture = try SMTPFixture()
        defer { fixture.remove() }
        let port = try await fixture.start()
        let store = try makeTestStore("mail-send-local")
        let tool = MailSendTool(endpoint: { .init(port: port) })
        let result = await tool.call(request, as: .owner, store: store)

        #expect(!result.isError)
        #expect(result.text.contains("Captured in Bloom's Incoming mails inbox"))
        let received = try String(contentsOf: fixture.messageURL, encoding: .utf8)
        #expect(received.contains("From: <bloom-agent@example.test>"))
        #expect(received.contains("To: <inbox@example.test>"))
        #expect(received.contains("Subject: =?UTF-8?B?"))
        #expect(received.contains(Data("Hello from the agent.".utf8).base64EncodedString()))
    }

    private var request: MCPRequest {
        MCPRequest(id: .integer(1), method: "mail_send", params: .object([
            "subject": .string("Bloom test email"),
            "text": .string("Hello from the agent."),
        ]))
    }

    @MainActor private final class SMTPFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-smtp-test-\(UUID())")
        var process: Process?
        var portURL: URL { directory.appendingPathComponent("port") }
        var messageURL: URL { directory.appendingPathComponent("message") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func start() async throws -> Int {
            let scriptURL = directory.appendingPathComponent("server.py")
            let script = """
            import pathlib, socket, sys
            port_path, message_path = map(pathlib.Path, sys.argv[1:])
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                port_path.write_text(str(listener.getsockname()[1]))
                with listener.accept()[0] as connection:
                    connection.settimeout(10)
                    stream = connection.makefile("rwb", buffering=0)
                    def reply(line): stream.write(line + b"\\r\\n")
                    def command(prefix):
                        line = stream.readline()
                        assert line.startswith(prefix), line
                    reply(b"220 local test inbox")
                    command(b"EHLO ")
                    reply(b"250-local test inbox")
                    reply(b"250 OK")
                    command(b"MAIL FROM:<bloom-agent@example.test>")
                    reply(b"250 OK")
                    command(b"RCPT TO:<inbox@example.test>")
                    reply(b"250 OK")
                    command(b"DATA")
                    reply(b"354 End with a dot")
                    lines = []
                    while True:
                        line = stream.readline()
                        if line == b".\\r\\n": break
                        assert line, "message ended before the SMTP terminator"
                        lines.append(line)
                    message_path.write_bytes(b"".join(lines))
                    reply(b"250 Captured")
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [scriptURL.path, portURL.path, messageURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process

            // A ceiling on a server that never starts, not a timing assertion.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if let text = try? String(contentsOf: portURL, encoding: .utf8), let port = Int(text) {
                    return port
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw POSIXError(.ETIMEDOUT)
        }

        func remove() {
            if process?.isRunning == true { process?.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
