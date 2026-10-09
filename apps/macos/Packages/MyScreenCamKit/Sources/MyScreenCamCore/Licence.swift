import CryptoKit
import Foundation

/// What a licence key says: who bought My Screen Cam, and when.
public struct Licence: Sendable, Equatable {
    /// `lic_` plus 16 base32 characters derived from the Stripe Checkout Session. Used for the revoked list.
    public let id: String
    public let email: String
    /// `"myscreencam"`. A future paid major version can use another value without breaking today's keys.
    public let product: String
    /// The purchase date, `yyyy-MM-dd`.
    public let issued: String
}

public enum LicenceError: Error, Sendable, Equatable {
    /// Not a licence key: wrong shape, not base64url, not the expected JSON, or an unknown payload version.
    case malformed
    /// None of the trusted public keys signed this payload.
    case badSignature
    /// Signed by us, but for a different product.
    case wrongProduct
    /// The licence ID is on the revoked list.
    case revoked
}

/// A parsed `MSC1.<payload>.<signature>` licence key. Both parts are base64url. The signature is Ed25519
/// over the exact payload bytes, so nothing here re-serialises JSON. The website signs these
/// (`apps/web/src/lib/licence.ts`); the test vectors in `licence/test-vectors.json` keep the two in step.
///
/// ```swift
/// let key = try LicenceKey.parse(pastedText)
/// let licence = try key.verify(publicKeys: LicenceKey.parsePublicKeys(trustedKeys), revoked: revokedIDs)
/// ```
public struct LicenceKey: Sendable, Equatable {
    public static let prefix = "MSC1"
    public static let product = "myscreencam"

    /// The licence as it claims to be. Not trustworthy until ``verify(publicKeys:revoked:)`` succeeds.
    public let claimed: Licence

    private let payload: Data
    private let signature: Data

    /// Parses pasted text. Whitespace anywhere (including line breaks from a wrapped email) is ignored.
    public static func parse(_ text: String) throws -> LicenceKey {
        let compact = String(text.filter { !$0.isWhitespace })
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
            let payload = Data(base64URL: parts[1]),
            let signature = Data(base64URL: parts[2]), signature.count == 64,
            let body = try? JSONDecoder().decode(Payload.self, from: payload), body.v == 1
        else { throw LicenceError.malformed }
        return LicenceKey(
            claimed: Licence(id: body.id, email: body.email, product: body.product, issued: body.issued),
            payload: payload,
            signature: signature
        )
    }

    /// Checks the signature against every trusted key (a list, so the signing key can be rotated), then the
    /// product, then the revoked list.
    public func verify(
        publicKeys: [Curve25519.Signing.PublicKey],
        revoked: Set<String> = []
    ) throws -> Licence {
        guard publicKeys.contains(where: { $0.isValidSignature(signature, for: payload) }) else {
            throw LicenceError.badSignature
        }
        guard claimed.product == Self.product else { throw LicenceError.wrongProduct }
        guard !revoked.contains(claimed.id) else { throw LicenceError.revoked }
        return claimed
    }

    /// Parses trusted public keys from a comma- or whitespace-separated list of base64 raw 32-byte Ed25519 keys
    /// (the `MSC_LICENCE_PUBLIC_KEYS` build setting). Entries that aren't valid keys are skipped, which leaves
    /// verification failing safe: with no usable key every licence is rejected.
    public static func parsePublicKeys(_ text: String) -> [Curve25519.Signing.PublicKey] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap {
            Data(base64Encoded: String($0)).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }

    private struct Payload: Decodable {
        let v: Int
        let id: String
        let email: String
        let product: String
        let issued: String
    }
}

extension Data {
    /// Strict unpadded base64url: rejects `+`, `/` and `=`, so each licence has exactly one spelling.
    fileprivate init?(base64URL text: Substring) {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !text.isEmpty, text.allSatisfy(allowed.contains), text.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
