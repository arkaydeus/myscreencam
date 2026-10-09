import CryptoKit
import Foundation
import Testing

@testable import MyScreenCamCore

/// Checks the verifier against `licence/test-vectors.json`, which the website's signer is tested against too
/// (`apps/web/tests/licence.test.mjs`), so the TypeScript signer and this verifier can't drift apart.
struct LicenceTests {
    struct Vectors: Decodable {
        struct Payload: Decodable, Equatable {
            let id: String
            let email: String
            let product: String
            let issued: String
        }

        struct Case: Decodable, Sendable, CustomTestStringConvertible {
            let name: String
            let key: String
            let publicKeys: [String]
            let revoked: [String]
            let expect: String

            var testDescription: String { name }
        }

        let publicKeys: [String: String]
        let expectedPayload: Payload
        let cases: [Case]
    }

    static let vectors: Vectors? = {
        // …/Tests/MyScreenCamCoreTests/LicenceTests.swift is seven levels below the repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let file = url.appending(path: "licence/test-vectors.json")
        return try? JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }()

    @Test func vectorFileLoads() throws {
        let vectors = try #require(Self.vectors, "licence/test-vectors.json should load")
        #expect(vectors.cases.count >= 20)
        #expect(Set(vectors.cases.map(\.expect)) == ["valid", "malformed", "badSignature", "wrongProduct", "revoked"])
    }

    @Test(arguments: Self.vectors?.cases ?? [])
    func verifiesLikeTheSigner(_ vector: Vectors.Case) throws {
        let vectors = try #require(Self.vectors)
        let keys = try vector.publicKeys.flatMap { name in
            let encoded = try #require(vectors.publicKeys[name])
            return LicenceKey.parsePublicKeys(encoded)
        }
        let result = Result {
            try LicenceKey.parse(vector.key).verify(publicKeys: keys, revoked: Set(vector.revoked))
        }
        if vector.expect == "valid" {
            #expect(try result.get().product == LicenceKey.product)
        } else {
            let expected: LicenceError =
                switch vector.expect {
                case "malformed": .malformed
                case "badSignature": .badSignature
                case "wrongProduct": .wrongProduct
                default: .revoked
                }
            #expect(throws: expected) { try result.get() }
        }
    }

    @Test func readsThePayload() throws {
        let vectors = try #require(Self.vectors)
        let valid = try #require(vectors.cases.first)
        let key = try LicenceKey.parse(valid.key)
        let licence = try key.verify(publicKeys: LicenceKey.parsePublicKeys(try #require(vectors.publicKeys["signer"])))
        #expect(licence.id == vectors.expectedPayload.id)
        #expect(licence.email == vectors.expectedPayload.email)
        #expect(licence.product == vectors.expectedPayload.product)
        #expect(licence.issued == vectors.expectedPayload.issued)
    }

    @Test func preservesNonASCIIEmail() throws {
        let vectors = try #require(Self.vectors)
        let vector = try #require(vectors.cases.first { $0.name.contains("non-ASCII") })
        let keys = LicenceKey.parsePublicKeys(try #require(vectors.publicKeys["signer"]))
        #expect(try LicenceKey.parse(vector.key).verify(publicKeys: keys).email == "søren+licence@example.co.uk")
    }

    @Test func parsesPublicKeyLists() throws {
        let vectors = try #require(Self.vectors)
        let signer = try #require(vectors.publicKeys["signer"])
        let other = try #require(vectors.publicKeys["other"])
        #expect(LicenceKey.parsePublicKeys("\(signer),\(other)").count == 2)
        #expect(LicenceKey.parsePublicKeys("\(signer) \n \(other)").count == 2)
        #expect(LicenceKey.parsePublicKeys("not-a-key, \(signer), AAAA").count == 1)
        #expect(LicenceKey.parsePublicKeys("").isEmpty)
    }

    @Test(arguments: ["=", "+", "/"])
    func onlyUnpaddedBase64URLIsAccepted(_ stray: String) throws {
        let vectors = try #require(Self.vectors)
        let parts = try #require(vectors.cases.first).key.split(separator: ".").map(String.init)
        #expect(throws: LicenceError.malformed) {
            try LicenceKey.parse("MSC1.\(parts[1])\(stray).\(parts[2])")
        }
    }
}
