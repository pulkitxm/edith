import CryptoKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct DeviceIdentityTests {
    @Test func softwareKeySignatureVerifiesWithPublishedPublicKey() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try makeIdentity(store: store)
        let message = DeviceIdentity.challengeMessage(
            purpose: "activate", challengeId: "challenge-1", nonce: "nonce-1")

        let signature = try identity.sign(message: message)

        let spki = try #require(Base64URL.decode(identity.publicKeySPKIBase64URL))
        let publicKey = try P256.Signing.PublicKey(derRepresentation: spki)
        let der = try #require(Base64URL.decode(signature))
        let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: der)
        #expect(publicKey.isValidSignature(ecdsa, for: message))
        #expect(!publicKey.isValidSignature(ecdsa, for: Data("other".utf8)))
    }

    @Test func identityAndThumbprintAreStableAcrossReloads() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeIdentity(store: store)
        let second = try makeIdentity(store: store)

        #expect(first.deviceId == second.deviceId)
        #expect(UUID(uuidString: first.deviceId) != nil)
        #expect(first.publicKeySPKIBase64URL == second.publicKeySPKIBase64URL)
        #expect(first.thumbprint == second.thumbprint)
    }

    @Test func thumbprintIsBase64URLSHA256OfSPKI() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try makeIdentity(store: store)

        let spki = try #require(Base64URL.decode(identity.publicKeySPKIBase64URL))
        #expect(identity.thumbprint == Base64URL.encode(Data(SHA256.hash(data: spki))))
    }

    @Test func softwarePathPersistsKeyWithSoftwarePrefix() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeIdentity(store: store)

        let stored = try #require(try store.read(.deviceKey))
        #expect(stored.hasPrefix("sw:"))
        let raw = try #require(Data(base64Encoded: String(stored.dropFirst(3))))
        _ = try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    private func makeStore() -> (FileLicenseCredentialStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceIdentityTests.\(UUID().uuidString)")
        return (FileLicenseCredentialStore(directory: directory), directory)
    }

    private func makeIdentity(store: FileLicenseCredentialStore) throws -> DeviceIdentity {
        try DeviceIdentity(
            credentialStore: store,
            keyStore: DeviceKeyStore(store: store, secureEnclaveAvailable: false))
    }
}
