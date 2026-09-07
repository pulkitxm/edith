import Foundation

public enum DatabaseSecretRedactorError: Error, Equatable, Sendable {
    case invalidReplacement
    case tooManyReferences(actual: Int, maximum: Int)
    case secretMaterialTooLarge(actualBytes: Int, maximumBytes: Int)
}

public struct DatabaseSecretRedactor: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let defaultReplacement = "[REDACTED]"
    public static let maximumReferences = 256
    public static let maximumSecretBytes = 2_097_152

    private let secrets: [Data]
    private let replacement: Data

    public var description: String { "DatabaseSecretRedactor" }
    public var debugDescription: String { description }

    public init(
        store: any DatabaseSecretStore,
        references: [DatabaseSecretReference],
        replacement: String = DatabaseSecretRedactor.defaultReplacement
    ) async throws {
        guard (1...128).contains(replacement.utf8.count) else {
            throw DatabaseSecretRedactorError.invalidReplacement
        }
        guard references.count <= Self.maximumReferences else {
            throw DatabaseSecretRedactorError.tooManyReferences(
                actual: references.count,
                maximum: Self.maximumReferences)
        }

        var seenReferences = Set<DatabaseSecretReference>()
        var seenSecrets = Set<Data>()
        var loaded: [Data] = []
        var totalBytes = 0
        for reference in references where seenReferences.insert(reference).inserted {
            let secret = try await store.read(reference)
            guard !secret.isEmpty, seenSecrets.insert(secret).inserted else { continue }
            totalBytes += secret.count
            guard totalBytes <= Self.maximumSecretBytes else {
                throw DatabaseSecretRedactorError.secretMaterialTooLarge(
                    actualBytes: totalBytes,
                    maximumBytes: Self.maximumSecretBytes)
            }
            loaded.append(secret)
        }

        try self.init(secrets: loaded, replacement: replacement)
    }

    init(
        secrets: [Data],
        replacement: String = DatabaseSecretRedactor.defaultReplacement
    ) throws {
        guard (1...128).contains(replacement.utf8.count) else {
            throw DatabaseSecretRedactorError.invalidReplacement
        }
        guard secrets.count <= Self.maximumReferences else {
            throw DatabaseSecretRedactorError.tooManyReferences(
                actual: secrets.count,
                maximum: Self.maximumReferences)
        }

        var seenSecrets = Set<Data>()
        var loaded: [Data] = []
        var totalBytes = 0
        for secret in secrets where !secret.isEmpty && seenSecrets.insert(secret).inserted {
            totalBytes += secret.count
            guard totalBytes <= Self.maximumSecretBytes else {
                throw DatabaseSecretRedactorError.secretMaterialTooLarge(
                    actualBytes: totalBytes,
                    maximumBytes: Self.maximumSecretBytes)
            }
            loaded.append(secret)
        }

        self.secrets = loaded.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lexicographicallyPrecedes($1)
        }
        self.replacement = Data(replacement.utf8)
    }

    public func redact(_ string: String) -> String {
        String(decoding: redact(Data(string.utf8)), as: UTF8.self)
    }

    public func redact(_ data: Data) -> Data {
        guard !data.isEmpty, !secrets.isEmpty else { return data }
        let source = [UInt8](data)
        let patterns = secrets.map { [UInt8]($0) }
        let replacementBytes = [UInt8](replacement)
        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var index = 0

        while index < source.count {
            if let match = patterns.first(where: { matches($0, in: source, at: index) }) {
                output.append(contentsOf: replacementBytes)
                index += match.count
            } else {
                output.append(source[index])
                index += 1
            }
        }
        return Data(output)
    }

    public func redact(_ value: DatabaseValue) -> DatabaseValue {
        switch value {
        case .missing:
            .missing
        case .null:
            .null
        case let .boolean(value):
            .boolean(value)
        case let .signedInteger(value):
            .signedInteger(value)
        case let .unsignedInteger(value):
            .unsignedInteger(value)
        case let .decimal(value):
            .decimal(DatabaseDecimalValue(rawValue: redact(value.rawValue)))
        case let .floatingPoint(value):
            .floatingPoint(value)
        case let .string(value):
            .string(redact(value))
        case let .binary(value):
            .binary(redact(value))
        case let .date(value):
            .date(
                DatabaseDateValue(
                    text: redact(value.text),
                    calendarIdentifier: redact(value.calendarIdentifier)))
        case let .time(value):
            .time(
                DatabaseTimeValue(
                    text: redact(value.text),
                    timeZoneOffsetMinutes: value.timeZoneOffsetMinutes,
                    precision: value.precision))
        case let .timestamp(value):
            .timestamp(
                DatabaseTimestampValue(
                    text: redact(value.text),
                    timeZoneIdentifier: redact(value.timeZoneIdentifier),
                    timeZoneOffsetMinutes: value.timeZoneOffsetMinutes,
                    precision: value.precision))
        case let .uuid(value):
            .uuid(value)
        case let .array(values):
            .array(values.map(redact))
        case let .object(fields):
            .object(
                fields.map {
                    DatabaseObjectField(name: redact($0.name), value: redact($0.value))
                })
        case let .productSpecific(value):
            .productSpecific(
                DatabaseProductValue(
                    product: value.product,
                    typeName: redact(value.typeName),
                    textRepresentation: redact(value.textRepresentation),
                    binaryRepresentation: value.binaryRepresentation.map(redact),
                    attributes: value.attributes.map {
                        DatabaseStringAttribute(
                            name: redact($0.name),
                            value: redact($0.value))
                    }))
        }
    }

    private func redact(_ binary: DatabaseBinaryValue) -> DatabaseBinaryValue {
        switch binary {
        case let .complete(data, mediaType, digest):
            .complete(
                data: redact(data),
                mediaType: redact(mediaType),
                digest: redact(digest))
        case let .preview(byteCount, bytes, mediaType, digest):
            .preview(
                byteCount: byteCount,
                bytes: redact(bytes),
                mediaType: redact(mediaType),
                digest: redact(digest))
        }
    }

    private func redact(_ string: String?) -> String? {
        string.map(redact)
    }

    private func matches(_ pattern: [UInt8], in source: [UInt8], at index: Int) -> Bool {
        guard index + pattern.count <= source.count else { return false }
        return source[index..<(index + pattern.count)].elementsEqual(pattern)
    }
}
