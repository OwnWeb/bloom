import Foundation

/// Base64url without padding, the alphabet of every part of a JWS and of a JWK's `x`.
///
/// Strict on purpose. A decoder that also took standard base64 or padding would accept more than
/// one spelling of the same token, and a token whose text can vary while its signature still
/// verifies is one whose `jti` no longer names it alone.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: some StringProtocol) -> Data? {
        guard text.count % 4 != 1 else { return nil }
        let allowed = text.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F
        }
        guard allowed else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { return nil }
        // Base64 has spare bits in its last character, so two texts can decode to the same bytes.
        // Only the one this encoder would write is accepted, for the reason above.
        return encode(data) == text ? data : nil
    }
}
