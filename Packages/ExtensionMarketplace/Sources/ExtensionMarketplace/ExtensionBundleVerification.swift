import Darwin
import Foundation

public enum ExtensionBundleVerification {
    private struct FileStamp: Hashable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
    }

    private struct Fingerprint: Hashable {
        let path: String
        let stamps: [FileStamp]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var verified = Set<Fingerprint>()

    public static func verify(_ url: URL, using verify: (URL) throws -> Void) throws {
        let fingerprint = fingerprint(of: url)
        if let fingerprint, lock.withLock({ verified.contains(fingerprint) }) { return }
        try verify(url)
        if let fingerprint { lock.withLock { _ = verified.insert(fingerprint) } }
    }

    public static func verifyConcurrently(
        _ urls: [URL], using verify: @escaping @Sendable (URL) throws -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { try? Self.verify(url, using: verify) }
            }
        }
    }

    private static func fingerprint(of bundle: URL) -> Fingerprint? {
        let root = bundle.resolvingSymlinksInPath()
        let contents = root.appendingPathComponent("Contents")
        var paths = [
            contents.appendingPathComponent("Info.plist").path,
            contents.appendingPathComponent("_CodeSignature/CodeResources").path,
        ]
        let executables = contents.appendingPathComponent("MacOS")
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: executables.path),
            !names.isEmpty
        else { return nil }
        paths += names.sorted().map { executables.appendingPathComponent($0).path }
        var stamps: [FileStamp] = []
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            stamps.append(
                FileStamp(
                    device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec))
        }
        return Fingerprint(path: root.path, stamps: stamps)
    }
}
