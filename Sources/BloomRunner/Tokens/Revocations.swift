import BloomCore
import Foundation

/// Who lost access, and when, so a token or preview cookie they already hold stops working.
///
/// Closing a person's streams is not enough on its own: a session token lasts five minutes and a
/// preview cookie up to eight hours, and either would open everything again the moment after. A
/// token issued before the revocation is refused; one issued after it is runbloom.app having let
/// the person back in, which is its decision to make. The cut off is the revocation plus the clock
/// skew the verifier allows, because runbloom.app's clock and this machine's differ, and a token
/// minted a moment before the call must not slip through on that difference.
///
/// **Kept in the database** for as long as the longest thing it can refuse lasts, so a restart
/// in between does not forget it.
public actor Revocations {
    private let store: Store?
    private let now: @Sendable () -> Date
    private var revoked: [String: Date] = [:]
    private var loaded = false

    static let settingKey = "remote.revocations"
    /// The longest preview cookie. Nothing issued before a revocation outlives this.
    static let remembered: TimeInterval = 8 * 60 * 60

    public init(store: Store? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// `subject` is a user id, or `share:<id>` for a share link that was withdrawn.
    public func revoke(_ subject: String) async {
        await load()
        revoked[subject] = now()
        await persist()
    }

    public func isRevoked(_ subject: String, issuedAt: Date) async -> Bool {
        await load()
        guard let at = revoked[subject] else { return false }
        return issuedAt <= at.addingTimeInterval(TokenVerifier.clockSkew)
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        guard let text = try? await store?.setting(Self.settingKey),
              let stored = try? JSONDecoder().decode([String: Date].self, from: Data(text.utf8)) else { return }
        // Merged, because a revocation can land while the stored copy is on its way back.
        revoked.merge(stored) { current, _ in current }
    }

    private func persist() async {
        let horizon = now().addingTimeInterval(-Self.remembered)
        revoked = revoked.filter { $0.value > horizon }
        guard let store, let data = try? JSONEncoder().encode(revoked) else { return }
        try? await store.setSetting(Self.settingKey, String(decoding: data, as: UTF8.self))
    }
}
