import BloomCore
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Who has entered the preview, by the opaque cookie they were given.
///
/// **In the database, not in memory,** because a machine that went cold drops its memory, and a
/// preview that asked everybody to open it from Bloom again after every lunch break would be a
/// preview nobody used. Only a hash of each cookie is stored, so the database alone lets nobody in.
actor PreviewSessions {
    private struct Entry: Codable {
        var subject: String
        var expiresAt: Date
    }

    private let store: Store
    private let now: @Sendable () -> Date

    init(store: Store, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func create(subject: String, lifetime: TimeInterval) async -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let cookie = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let entry = Entry(subject: subject, expiresAt: now().addingTimeInterval(lifetime))
        if let data = try? JSONEncoder().encode(entry) {
            try? await store.setSetting(Self.key(cookie), String(decoding: data, as: UTF8.self))
        }
        return cookie
    }

    func subject(for cookie: String) async -> String? {
        guard cookie.utf8.count <= 128,
              let text = try? await store.setting(Self.key(cookie)),
              let entry = try? JSONDecoder().decode(Entry.self, from: Data(text.utf8)) else { return nil }
        guard entry.expiresAt > now() else {
            try? await store.setSetting(Self.key(cookie), nil)
            return nil
        }
        return entry.subject
    }

    private static func key(_ cookie: String) -> String {
        "remote.preview." + SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
