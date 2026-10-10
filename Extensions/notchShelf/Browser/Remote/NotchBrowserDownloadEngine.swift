import EdithExtensionSupport
import Foundation

struct NotchBrowserDownloadDescriptor: Codable, Sendable {
    let id: UUID
    let name: String
}

@MainActor final class NotchBrowserDownloadEngine {
    private struct Download {
        let descriptor: NotchBrowserDownloadDescriptor
        let directory: URL
        let file: URL
        let writer: FileHandle
        var expiry: Date
        var offset: UInt64
    }
    private var downloads: [UUID: Download] = [:]
    private let destination: () -> URL
    private let staging: URL
    private let completed: (URL) -> Void
    private let now: () -> Date
    private var expiryTask: Task<Void, Never>?
    init(
        destination: @escaping () -> URL = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Downloads")
        }, staging: URL = ExtensionData.root.appendingPathComponent("notch-browser/downloads"),
        now: @escaping () -> Date = Date.init,
        completed: @escaping (URL) -> Void = { url in
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path)
        }
    ) {
        self.now = now
        self.destination = destination
        self.staging = staging
        self.completed = completed
    }
    func start(_ name: String) throws -> NotchBrowserDownloadDescriptor {
        expire()
        guard downloads.count < 8, !name.isEmpty, name != ".", name != "..",
            name.utf8.count <= 1024, !name.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }
        let id = UUID()
        let directory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("payload")
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        let descriptor = NotchBrowserDownloadDescriptor(
            id: id, name: name.replacingOccurrences(of: "/", with: "-"))
        downloads[id] = Download(
            descriptor: descriptor, directory: directory, file: file,
            writer: try FileHandle(forWritingTo: file), expiry: now().addingTimeInterval(1800),
            offset: 0)
        scheduleExpiry()
        return descriptor
    }
    func write(id: UUID, offset: UInt64, bytes: Data) throws {
        expire()
        guard var download = downloads[id], download.offset == offset, !bytes.isEmpty,
            bytes.count <= 65536, offset <= 137438953472 - UInt64(bytes.count)
        else { throw ExtensionPeerError.invalidRequest }
        try download.writer.write(contentsOf: bytes)
        download.offset += UInt64(bytes.count)
        download.expiry = now().addingTimeInterval(1800)
        downloads[id] = download
        scheduleExpiry()
    }
    func commit(id: UUID) throws -> NotchBrowserDownloadDescriptor {
        expire()
        guard let download = downloads[id] else { throw ExtensionPeerError.invalidRequest }
        try download.writer.synchronize(); try download.writer.close()
        let folder = destination()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = NotchBrowserStore.uniqueDestination(
            in: folder, filename: download.descriptor.name,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do { try FileManager.default.moveItem(at: download.file, to: url) } catch {
            cancel(id: id); throw error
        }
        downloads[id] = nil
        scheduleExpiry()
        try? FileManager.default.removeItem(at: download.directory)
        completed(url)
        return .init(id: id, name: url.lastPathComponent)
    }
    func cancel(id: UUID) {
        guard let download = downloads.removeValue(forKey: id) else { return }
        try? download.writer.close()
        try? FileManager.default.removeItem(at: download.directory)
        scheduleExpiry()
    }
    func expire() {
        for (id, download) in downloads where download.expiry <= now() { cancel(id: id) }
    }
    private func scheduleExpiry() {
        expiryTask?.cancel(); expiryTask = nil
        guard let deadline = downloads.values.map(\.expiry).min() else { return }
        let delay = max(0.01, deadline.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.expire()
        }
    }
    func stop() {
        for id in Array(downloads.keys) { cancel(id: id) }
        expiryTask?.cancel(); expiryTask = nil
    }
}
