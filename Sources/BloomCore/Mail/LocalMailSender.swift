import Darwin
import Foundation

/// Sends only to Bloom's loopback SMTP listener. The recipient is a label in the captured mail,
/// never a destination on the internet.
public enum LocalMailSender {
    public struct Message: Sendable, Equatable {
        public let subject: String
        public let text: String
        public let from: String
        public let to: String

        public init(
            subject: String, text: String,
            from: String = "bloom-agent@example.test", to: String = "inbox@example.test"
        ) throws {
            let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, subject.count <= 200,
                  subject.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw Failure.invalidSubject
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 100_000 else {
                throw Failure.invalidText
            }
            guard Self.valid(address: from), Self.valid(address: to) else {
                throw Failure.invalidAddress
            }
            self.subject = subject
            self.text = text
            self.from = from
            self.to = to
        }

        private static func valid(address: String) -> Bool {
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), address.utf8.count <= 254 else {
                return false
            }
            return address.utf8.allSatisfy { byte in
                (33...126).contains(byte) && !"<>(),:;\\[]\"".utf8.contains(byte)
            }
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case invalidSubject
        case invalidText
        case invalidAddress
        case invalidPort
        case unavailable(Int)
        case rejected(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidSubject: "Give the test email a subject of at most 200 characters, without line breaks."
            case .invalidText: "Give the test email a non-empty plain text body under 100 KB."
            case .invalidAddress: "Use plain email addresses such as inbox@example.test for the local test message."
            case .invalidPort: "Choose a valid SMTP port in Bloom's Incoming mails settings."
            case .unavailable(let port): "Bloom's local inbox is not accepting mail on SMTP port \(port). Check Incoming mails in Settings."
            case .rejected(let code): "Bloom's local inbox rejected the test email (SMTP \(code))."
            }
        }
    }

    public static func send(_ message: Message, port: Int) async throws {
        guard (1024...65535).contains(port) else { throw Failure.invalidPort }
        try await Task.detached(priority: .userInitiated) {
            try deliver(message, port: port)
        }.value
    }

    private static func deliver(_ message: Message, port: Int) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable(port) }
        defer { Darwin.close(descriptor) }

        var on: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              Darwin.setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure.unavailable(port)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.unavailable(port) }

        try expect(220, from: descriptor, port: port)
        try write("EHLO bloom.local\r\n", to: descriptor, port: port)
        try expect(250, from: descriptor, port: port)
        try write("MAIL FROM:<\(message.from)>\r\n", to: descriptor, port: port)
        try expect(250, from: descriptor, port: port)
        try write("RCPT TO:<\(message.to)>\r\n", to: descriptor, port: port)
        try expect(250, from: descriptor, port: port)
        try write("DATA\r\n", to: descriptor, port: port)
        try expect(354, from: descriptor, port: port)
        try write(payload(message), to: descriptor, port: port)
        try expect(250, from: descriptor, port: port)
        try? write("QUIT\r\n", to: descriptor, port: port)
    }

    private static func expect(_ wanted: Int, from descriptor: Int32, port: Int) throws {
        for _ in 0..<32 {
            let line = try readLine(from: descriptor, port: port)
            guard line.count >= 4, let code = Int(line.prefix(3)),
                  code == wanted else {
                throw Failure.rejected(Int(line.prefix(3)) ?? 0)
            }
            let marker = line[line.index(line.startIndex, offsetBy: 3)]
            if marker == " " { return }
            guard marker == "-" else { throw Failure.rejected(code) }
        }
        throw Failure.unavailable(port)
    }

    private static func readLine(from descriptor: Int32, port: Int) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 8_192 {
            guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else { throw Failure.unavailable(port) }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            if byte != 13 { bytes.append(byte) }
        }
        throw Failure.unavailable(port)
    }

    private static func write(_ text: String, to descriptor: Int32, port: Int) throws {
        let bytes = [UInt8](text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            guard count > 0 else { throw Failure.unavailable(port) }
            sent += count
        }
    }

    private static func payload(_ message: Message) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var subjectWords: [String] = []
        var subjectBytes: [UInt8] = []
        for scalar in message.subject.unicodeScalars {
            let bytes = [UInt8](String(scalar).utf8)
            if subjectBytes.count + bytes.count > 42 {
                subjectWords.append("=?UTF-8?B?\(Data(subjectBytes).base64EncodedString())?=")
                subjectBytes = []
            }
            subjectBytes += bytes
        }
        if !subjectBytes.isEmpty {
            subjectWords.append("=?UTF-8?B?\(Data(subjectBytes).base64EncodedString())?=")
        }

        let encoded = [UInt8](Data(message.text.utf8).base64EncodedString().utf8)
        let lines = stride(from: 0, to: encoded.count, by: 76).map { index in
            String(decoding: encoded[index..<min(index + 76, encoded.count)], as: UTF8.self)
        }
        return ([
            "Date: \(date.string(from: Date()))",
            "From: <\(message.from)>",
            "To: <\(message.to)>",
            "Subject: \(subjectWords.joined(separator: " "))",
            "Message-ID: <\(UUID().uuidString.lowercased())@bloom.test>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
        ] + lines + ["."]).joined(separator: "\r\n") + "\r\n"
    }
}
