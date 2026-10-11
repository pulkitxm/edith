import CryptoKit
import Foundation
import SparkleFixtureContract
import Testing

private func fixture() -> SparkleBootstrapDescriptor {
    let session = "00000000-0000-4000-8000-000000000001"
    return .init(
        session: session, sourceCommit: String(repeating: "a", count: 40),
        identifier: "com.pulkit.edith.tests.remote-" + session,
        directory: "/Users/fixture/Applications/Edith Remote Fixture Journey " + session,
        port: 12345, updatePublicKey: Data(repeating: 2, count: 32).base64EncodedString(),
        producer: .init(
            pid: 100, birth: "99.1", uid: 501, executable: "/usr/local/bin/node",
            executableSHA256: String(repeating: "c", count: 64)))
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func envelope(_ descriptor: SparkleBootstrapDescriptor, key: Curve25519.Signing.PrivateKey)
    throws -> Data
{
    let bytes = try encode(descriptor)
    return try encode(
        SparkleBootstrapEnvelope(
            payload: bytes.base64EncodedString(),
            signature: key.signature(for: bytes).base64EncodedString()))
}

@Test func onlyTheBuildPinnedIssuerCanAuthenticateTheExactCanonicalDescriptor() throws {
    let key = Curve25519.Signing.PrivateKey()
    let descriptor = fixture()
    let data = try envelope(descriptor, key: key)
    #expect(
        try SparkleBootstrapEnvelope.verify(data, pinnedIssuerKey: key.publicKey.rawRepresentation)
            == descriptor)
    #expect(throws: (any Error).self) {
        try SparkleBootstrapEnvelope.verify(
            data, pinnedIssuerKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }
    #expect(throws: (any Error).self) {
        try SparkleBootstrapEnvelope.verify(
            Data(data.dropLast()), pinnedIssuerKey: key.publicKey.rawRepresentation)
    }
    for changed in [
        Data("{".utf8) + Data("\"unexpected\":true,".utf8) + data.dropFirst(),
        Data("{".utf8) + Data("\"payload\":\"duplicate\",".utf8) + data.dropFirst(),
        Data(repeating: 0, count: 16_385),
    ] {
        #expect(throws: (any Error).self) {
            try SparkleBootstrapEnvelope.verify(
                changed, pinnedIssuerKey: key.publicKey.rawRepresentation)
        }
    }
}

@Test func strictSourceAccountAppVersionAndCurrentProducerAreRequiredBeforeEnvironmentRestore()
    throws
{
    let descriptor = fixture()
    func validate(
        source: String? = nil, home: String = "/Users/fixture", uid: UInt32 = 501,
        identifier: String? = nil, path: String? = nil, version: String = "1.0.0",
        producer: SparkleProducerIdentity? = nil
    ) throws {
        try descriptor.validate(
            sourceCommit: source ?? descriptor.sourceCommit, accountHome: home, currentUID: uid,
            bundleIdentifier: identifier ?? descriptor.identifier,
            bundlePath: path ?? descriptor.directory + "/Host.app",
            executablePath: descriptor.directory + "/Host.app/Contents/MacOS/Edith",
            version: version,
            observedProducer: producer ?? descriptor.producer)
    }
    try validate()
    try validate(version: "2.0.0")
    #expect(throws: SparkleFixtureError.self) { try validate(home: "/Users/fixture\n") }
    #expect(throws: SparkleFixtureError.self) { try validate(home: "/Users/fixture\0") }
    #expect(throws: SparkleFixtureError.self) {
        try validate(source: String(repeating: "b", count: 40))
    }
    #expect(throws: SparkleFixtureError.self) { try validate(home: "/Users/fixture/../foreign") }
    #expect(throws: SparkleFixtureError.self) { try validate(uid: 502) }
    #expect(throws: SparkleFixtureError.self) { try validate(identifier: "com.pulkit.edith") }
    #expect(throws: SparkleFixtureError.self) { try validate(path: "/Applications/Edith.app") }
    #expect(throws: SparkleFixtureError.self) { try validate(version: "3.0.0") }
    #expect(throws: SparkleFixtureError.self) {
        try validate(
            producer: .init(
                pid: descriptor.producer.pid, birth: "100.2", uid: 501,
                executable: descriptor.producer.executable,
                executableSHA256: descriptor.producer.executableSHA256))
    }
}

@Test func restoredEnvironmentContainsOnlyClosedSyntheticRootsAndClearsAmbientAgent() {
    let descriptor = fixture()
    let environment = descriptor.applicationEnvironment
    #expect(environment["HOME"] == descriptor.directory + "/synthetic-data")
    #expect(environment["CFFIXED_USER_HOME"] == environment["HOME"])
    #expect(environment["EDITH_APPLICATION_IDENTIFIER"] == descriptor.identifier)
    #expect(environment["EDITH_SHARED_DEFAULTS_SUITE"] == descriptor.identifier)
    #expect(environment["SSH_AUTH_SOCK"] == "")
    #expect(environment["GITHUB_TOKEN"] == nil)
    #expect(environment["SPARKLE_PRIVATE_KEY"] == nil)
    #expect(descriptor.feedURL.host == "127.0.0.1")
}

@Test func newlineProducerBirthAndReusedOrForeignIssuerIdentityAreRejected() throws {
    let original = fixture()
    for producer in [
        SparkleProducerIdentity(
            pid: 100, birth: "99.1\n", uid: 501, executable: "/usr/local/bin/node",
            executableSHA256: String(repeating: "c", count: 64)),
        SparkleProducerIdentity(
            pid: 100, birth: "99.1\0", uid: 501, executable: "/usr/local/bin/node",
            executableSHA256: String(repeating: "c", count: 64)),
        SparkleProducerIdentity(
            pid: 1, birth: "99.1", uid: 501, executable: "/usr/local/bin/node",
            executableSHA256: String(repeating: "c", count: 64)),
        SparkleProducerIdentity(
            pid: 100, birth: "99.1", uid: 502, executable: "/usr/local/bin/node",
            executableSHA256: String(repeating: "c", count: 64)),
        SparkleProducerIdentity(
            pid: 100, birth: "99.1", uid: 501, executable: "/usr/local/../bin/node",
            executableSHA256: String(repeating: "c", count: 64)),
        SparkleProducerIdentity(
            pid: 100, birth: "99.1", uid: 501, executable: "/usr/local/bin/node",
            executableSHA256: "bad"),
    ] {
        let descriptor = SparkleBootstrapDescriptor(
            session: original.session, sourceCommit: original.sourceCommit,
            identifier: original.identifier, directory: original.directory, port: original.port,
            updatePublicKey: original.updatePublicKey, producer: producer)
        #expect(throws: SparkleFixtureError.self) {
            try descriptor.validate(
                sourceCommit: original.sourceCommit, accountHome: "/Users/fixture", currentUID: 501,
                bundleIdentifier: original.identifier, bundlePath: original.directory + "/Host.app",
                executablePath: original.directory + "/Host.app/Contents/MacOS/Edith",
                version: "1.0.0", observedProducer: producer)
        }
    }
}
