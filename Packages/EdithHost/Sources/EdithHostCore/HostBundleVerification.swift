import CryptoKit
import Darwin
import Foundation

public final class HostBundleVerificationReceipts: @unchecked Sendable {
    static let maximumEntries = 512

    private let lock = NSLock()
    private var file: URL?
    private var digests: [String: String] = [:]

    public init(file: URL? = nil) {
        configure(file: file)
    }

    public func configure(file: URL?) {
        lock.withLock {
            self.file = file
            digests = [:]
            guard let file, let data = try? Data(contentsOf: file),
                let stored = try? JSONDecoder().decode([String: String].self, from: data)
            else { return }
            digests = stored
        }
    }

    func contains(path: String, digest: String) -> Bool {
        lock.withLock { digests[path] == digest }
    }

    func record(path: String, digest: String) {
        lock.withLock {
            digests[path] = digest
            if digests.count > Self.maximumEntries {
                for stale in digests.keys
                where !FileManager.default.fileExists(atPath: stale) {
                    digests[stale] = nil
                }
            }
            guard let file else { return }
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(digests).write(to: file, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {}
        }
    }
}

enum HostBundleVerification {
    static let maximumConcurrentVerifications = 4

    static let receipts = HostBundleVerificationReceipts()

    private static let verificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "edith.host.bundle-verification"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = maximumConcurrentVerifications
        return queue
    }()

    static func verify(
        _ url: URL, receipts: HostBundleVerificationReceipts = receipts,
        using verify: (URL) throws -> Void
    ) throws {
        let path = url.resolvingSymlinksInPath().path
        let digest = fingerprint(of: url)
        if let digest, receipts.contains(path: path, digest: digest) { return }
        try verify(url)
        if let digest, digest == fingerprint(of: url) {
            receipts.record(path: path, digest: digest)
        }
    }

    static func verifyConcurrently(
        _ urls: [URL], receipts: HostBundleVerificationReceipts = receipts,
        using verify: @escaping @Sendable (URL) throws -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        verificationQueue.addOperation {
                            try? Self.verify(url, receipts: receipts, using: verify)
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    static func fingerprint(of bundle: URL) -> String? {
        let root = bundle.resolvingSymlinksInPath()
        let executables = root.appendingPathComponent("Contents/MacOS")
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: executables.path),
            !names.isEmpty,
            let enumerator = FileManager.default.enumerator(atPath: root.path)
        else { return nil }
        var hash = SHA256()
        hash.update(data: Data(root.path.utf8))
        var entries: [String] = []
        while let relative = enumerator.nextObject() as? String { entries.append(relative) }
        for relative in entries.sorted() {
            var info = stat()
            guard lstat(root.appendingPathComponent(relative).path, &info) == 0 else { return nil }
            let stamp = [
                Int(info.st_dev), Int(info.st_ino), Int(info.st_mode), Int(info.st_size),
                info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
                info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec,
            ].map(String.init).joined(separator: ",")
            hash.update(data: Data("\(relative)\u{0}\(stamp)\u{0}".utf8))
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { return nil }
            if info.st_mode & S_IFMT == S_IFREG,
                relative.hasPrefix("Contents/MacOS/") || info.st_mode & 0o111 != 0
                    || ["dylib", "so", "metallib"].contains(
                        URL(fileURLWithPath: relative).pathExtension)
            {
                guard let digest = codeDigest(of: root.appendingPathComponent(relative)) else {
                    return nil
                }
                hash.update(data: Data(digest.utf8))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func codeDigest(of url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0
        else { return nil }
        var remaining = Int(initial.st_size)
        var hash = SHA256()
        do {
            while remaining > 0 {
                guard let bytes = try handle.read(upToCount: min(remaining, 1_048_576)),
                    !bytes.isEmpty
                else { return nil }
                hash.update(data: bytes)
                remaining -= bytes.count
            }
        } catch { return nil }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == initial.st_size,
            after.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
        else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
