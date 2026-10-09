import CryptoKit
import Darwin
import Foundation

struct ExtensionPeerRegistration: Codable {
    let logicalName: String
    let physicalName: String
    let process: ExtensionProcessIdentity

    static func read(at url: URL, logicalName: String, requiresLiveProcess: Bool = true) -> Self? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_size >= 0, attributes.st_size <= 4_096
        else { close(descriptor); return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_097), data.count <= 4_096,
            let registration = try? JSONDecoder().decode(Self.self, from: data),
            registration.logicalName == logicalName,
            registration.physicalName.hasPrefix("edith.extension.worker.\(getuid())."),
            registration.physicalName.utf8.count < 128,
            registration.physicalName.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46].contains($0)
            }), !requiresLiveProcess || registration.process.isAlive
        else { return nil }
        return registration
    }
}

final class ExtensionPeerRegistrationLease {
    let registration: ExtensionPeerRegistration
    private let descriptor: Int32
    private let file: URL
    private var released = false

    init(endpoint: ExtensionPeerEndpoint) throws {
        guard let process = ExtensionProcessIdentity.current else {
            throw ExtensionPeerError.unavailable
        }
        let hash = SHA256.hash(data: Data((endpoint.name + UUID().uuidString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        registration = ExtensionPeerRegistration(
            logicalName: endpoint.name,
            physicalName: "edith.extension.worker.\(getuid()).\(hash)", process: process)
        try FileManager.default.createDirectory(
            at: endpoint.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        file = endpoint.registrationURL
        descriptor = open(
            file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600)
        guard descriptor >= 0 else { throw ExtensionPeerError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ExtensionPeerError.unavailable
        }
        if let previous = ExtensionPeerRegistration.read(
            at: file, logicalName: endpoint.name, requiresLiveProcess: false),
            !previous.process.isAlive
        {
            let path = ExtensionPeerSocket.path(previous.physicalName)
            var attributes = stat()
            if lstat(path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFSOCK,
                attributes.st_uid == getuid()
            {
                unlink(path)
            }
        }
    }

    func publish() throws {
        try JSONEncoder().encode(registration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func release() {
        guard !released else { return }
        released = true
        if ExtensionPeerRegistration.read(at: file, logicalName: registration.logicalName)?
            .physicalName == registration.physicalName
        {
            try? FileManager.default.removeItem(at: file)
        }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}
