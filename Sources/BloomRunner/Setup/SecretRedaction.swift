import Foundation

/// Redacts active process secrets before output reaches memory, disk or a transcript event.
enum SecretRedaction {
    static let mask = "******"

    static func mask(_ text: String, hiding secrets: some Sequence<String>) -> String {
        let values = Set(secrets.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
        return values.reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
    }
}
