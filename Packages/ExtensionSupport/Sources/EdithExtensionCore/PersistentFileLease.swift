import Darwin
import Foundation

public final class PersistentFileLease: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at file: URL, waits: Bool = false) throws -> PersistentFileLease? {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(descriptor, waits ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            if !waits && (code == EWOULDBLOCK || code == EAGAIN) { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return PersistentFileLease(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum PersistentJSONFile {
    public static func read<Value: Decodable>(_ type: Value.Type, from file: URL, missing: Value)
        throws -> Value
    {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: file)) } catch let error
            as CocoaError where error.code == .fileReadNoSuchFile
        { return missing }
    }

    public static func update<Value: Codable, Result>(
        _ type: Value.Type, at file: URL, missing: Value,
        _ mutation: (inout Value) throws -> Result
    ) throws -> (Value, Result) {
        let lease = try PersistentFileLease.acquire(
            at: file.appendingPathExtension("lock"), waits: true)
        return try withExtendedLifetime(lease) {
            var value = try read(type, from: file, missing: missing)
            let result = try mutation(&value)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            return (value, result)
        }
    }
}
