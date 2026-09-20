#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The RFC 7638 thumbprint of an Ed25519 key, which runbloom.app uses as the key's `kid`.
///
/// Here rather than only in the tests because a published key without a `kid` is still findable
/// by the one runbloom.app would have given it, and because a test that computed the thumbprint
/// its own way could agree with a wrong implementation by making the same mistake twice.
public enum JWKThumbprint {
    /// `x` is the base64url public key exactly as the key set publishes it. The members are in
    /// the lexicographic order the RFC requires, with no whitespace.
    public static func ed25519(x: String) -> String {
        let canonical = #"{"crv":"Ed25519","kty":"OKP","x":"\#(x)"}"#
        return Base64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
    }
}
