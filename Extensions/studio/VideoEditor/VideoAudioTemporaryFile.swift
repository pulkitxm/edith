import Darwin
import Foundation

final class VideoAudioTemporaryFile {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("edith-audio-rates", isDirectory: true)
    let url: URL
    private let lease: URL
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.reclaim(in: directory)
        let name = UUID().uuidString
        let staging = directory.appendingPathComponent(".\(name)")
        let lease = directory.appendingPathComponent("\(name).lease")
        let descriptor = Darwin.open(staging.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try FileManager.default.moveItem(at: staging, to: lease)
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        self.descriptor = descriptor
        self.lease = lease
        url = directory.appendingPathComponent("\(name).caf")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: lease)
        close(descriptor)
    }

    static func reclaim(in directory: URL) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for lease in files {
            let published =
                lease.pathExtension == "lease"
                && UUID(uuidString: lease.deletingPathExtension().lastPathComponent) != nil
            let staging =
                lease.lastPathComponent.hasPrefix(".")
                && UUID(uuidString: String(lease.lastPathComponent.dropFirst())) != nil
                && ((try? lease.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantFuture) < Date().addingTimeInterval(-86400)
            guard published || staging else { continue }
            let descriptor = Darwin.open(lease.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                if published {
                    try? FileManager.default.removeItem(
                        at: lease.deletingPathExtension().appendingPathExtension("caf"))
                }
                try? FileManager.default.removeItem(at: lease)
            }
            close(descriptor)
        }
    }
}
