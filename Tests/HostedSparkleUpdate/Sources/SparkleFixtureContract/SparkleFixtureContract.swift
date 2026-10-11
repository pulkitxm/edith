import CryptoKit
import Foundation

public enum SparkleFixtureError: Error {
    case rejected
}

public struct SparkleProducerIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let birth: String
    public let uid: UInt32
    public let executable: String
    public let executableSHA256: String

    public init(
        pid: Int32, birth: String, uid: UInt32, executable: String, executableSHA256: String
    ) {
        self.pid = pid
        self.birth = birth
        self.uid = uid
        self.executable = executable
        self.executableSHA256 = executableSHA256
    }
}

public struct SparkleBootstrapDescriptor: Codable, Equatable, Sendable {
    public let schema: Int
    public let session: String
    public let sourceCommit: String
    public let identifier: String
    public let directory: String
    public let port: Int
    public let updatePublicKey: String
    public let producer: SparkleProducerIdentity

    public init(
        schema: Int = 1, session: String, sourceCommit: String, identifier: String,
        directory: String, port: Int, updatePublicKey: String, producer: SparkleProducerIdentity
    ) {
        self.schema = schema
        self.session = session
        self.sourceCommit = sourceCommit
        self.identifier = identifier
        self.directory = directory
        self.port = port
        self.updatePublicKey = updatePublicKey
        self.producer = producer
    }

    public func validate(
        sourceCommit: String, accountHome: String, currentUID: UInt32,
        bundleIdentifier: String, bundlePath: String, executablePath: String, version: String,
        observedProducer: SparkleProducerIdentity
    ) throws {
        guard schema == 1,
            UUID(uuidString: session)?.uuidString.lowercased() == session,
            self.sourceCommit == sourceCommit, Self.hex(sourceCommit, count: 40),
            identifier == "com.pulkit.edith.tests.remote-" + session,
            bundleIdentifier == identifier,
            Self.matches(accountHome, pattern: "^/Users/[A-Za-z0-9_-]+$"),
            directory == accountHome + "/Applications/Edith Remote Fixture Journey " + session,
            bundlePath == directory + "/Host.app",
            executablePath == bundlePath + "/Contents/MacOS/Edith",
            ["1.0.0", "2.0.0"].contains(version),
            (1024...65535).contains(port),
            let key = Data(base64Encoded: updatePublicKey), key.count == 32,
            key.base64EncodedString() == updatePublicKey,
            producer == observedProducer, producer.pid > 1, producer.uid == currentUID,
            currentUID > 0,
            Self.matches(producer.birth, pattern: "^[0-9]+\\.[0-9]+$"),
            Self.hex(producer.executableSHA256, count: 64),
            producer.executable.hasPrefix("/"), !producer.executable.hasSuffix("/"),
            !producer.executable.contains("//"),
            !producer.executable.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
            producer.executable.utf8.allSatisfy({ $0 >= 32 && $0 < 127 })
        else { throw SparkleFixtureError.rejected }
    }

    public var applicationEnvironment: [String: String] {
        let home = directory + "/synthetic-data"
        return [
            "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
            "RUNNER_ENVIRONMENT": "github-hosted", "EDITH_HOSTED_SHELL_JOURNEY": "1",
            "EDITH_HOSTED_SPARKLE_UPDATE": "1", "HOME": home, "CFFIXED_USER_HOME": home,
            "XDG_CONFIG_HOME": home + "/.config", "XDG_CACHE_HOME": home + "/.cache",
            "XDG_DATA_HOME": home + "/.local/share", "TMPDIR": directory + "/tmp",
            "EDITH_APPLICATION_IDENTIFIER": identifier,
            "EDITH_SHARED_DEFAULTS_SUITE": identifier,
            "EDITH_EXTENSION_FIXTURE_HOME": home, "EDITH_GUI_FIXTURE_DIRECTORY": directory,
            "SSH_AUTH_SOCK": "",
        ]
    }

    public var feedURL: URL {
        URL(string: "http://127.0.0.1:\(port)/\(session)/appcast.xml")!
    }

    public func validateExistingEnvironment(_ environment: [String: String]) throws {
        for (key, value) in environment where key.hasPrefix("EDITH_") {
            guard applicationEnvironment[key] == value else { throw SparkleFixtureError.rejected }
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count
            && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}

public struct SparkleBootstrapEnvelope: Codable, Sendable {
    public let payload: String
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }

    public static func verify(_ data: Data, pinnedIssuerKey: Data) throws
        -> SparkleBootstrapDescriptor
    {
        guard !data.isEmpty, data.count <= 16_384 else { throw SparkleFixtureError.rejected }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(envelope) == data,
            let payload = Data(base64Encoded: envelope.payload), payload.count <= 8192,
            payload.base64EncodedString() == envelope.payload,
            let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
            signature.base64EncodedString() == envelope.signature,
            pinnedIssuerKey.count == 32
        else { throw SparkleFixtureError.rejected }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: pinnedIssuerKey)
        guard key.isValidSignature(signature, for: payload) else {
            throw SparkleFixtureError.rejected
        }
        let descriptor = try JSONDecoder().decode(SparkleBootstrapDescriptor.self, from: payload)
        guard try encoder.encode(descriptor) == payload else { throw SparkleFixtureError.rejected }
        return descriptor
    }
}
