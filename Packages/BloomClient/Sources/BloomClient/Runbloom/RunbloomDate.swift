import Foundation

/// A date as runbloom.app writes one, read tolerantly.
///
/// Laravel serialises a timestamp with microseconds (`2026-09-17T10:31:02.000000Z`), the machine
/// with milliseconds, and a hand written fixture with whole seconds. `ISO8601DateFormatter` reads
/// the second and third and refuses the first, so the fraction is cut to milliseconds before it is
/// parsed rather than trusting whichever format the other side happens to use this release.
struct RunbloomDate: Codable, Sendable, Hashable {
    var date: Date

    init(_ date: Date) { self.date = date }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, found \(text)")
        }
        self.date = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.format(date))
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        var normalised = text
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            normalised = String(text[..<dot]) + (digits.isEmpty ? "" : "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)) + text[end...]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalised) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalised)
    }
}
