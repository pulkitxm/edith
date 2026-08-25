import CryptoKit
import EdithCore
import Foundation

public enum RemoteFileOperation: String, CaseIterable, Sendable {
    case preview
    case launch
    case reveal
    case download

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .preview:
            descriptor("preview", "Preview a remote text file.", effect: .read)
        case .launch:
            descriptor("launch", "Open a remote file in its default Mac app.", effect: .interactive)
        case .reveal:
            descriptor("reveal", "Reveal a remote file in Finder.", effect: .interactive)
        case .download:
            descriptor("get", "Download a remote file.", effect: .write)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.files.\(rawValue)"), summary: summary,
            cli: ["machines", "files", verb], effect: effect)
    }
}

public enum PortForwardBrowserOperation: CaseIterable, Sendable {
    case open

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.forwards.open"),
            summary: "Open a forwarded service in the browser.",
            cli: ["machines", "forwards", "open"], effect: .interactive)
    }
}

public enum DockerBrowserOperation: CaseIterable, Sendable {
    case open

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.docker.open"),
            summary: "Open a published container port in the browser.",
            cli: ["machines", "docker", "open"], effect: .interactive)
    }
}

public enum MountedFileSystemOperation: CaseIterable, Sendable {
    case reveal

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.mount.reveal"),
            summary: "Reveal a mounted machine file system in Finder.",
            cli: ["machines", "mount-reveal"], effect: .interactive)
    }
}

public enum FilePresentationAction: Equatable, Sendable {
    case open
    case reveal
}

public enum RemoteFileOperationError: LocalizedError, Equatable, Sendable {
    case invalidCacheName(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCacheName(name):
            return "The remote file name cannot be cached safely: \(name)"
        }
    }
}

public enum RemoteFileOperationExecution {
    public static let previewLimit = 400 * 1024

    public static func previewCommand(path: String, limit: Int = previewLimit) -> String {
        "head -c \(max(1, limit + 1)) \(ShellQuote.quote(path))"
    }

    public static func textPreview(_ data: Data, limit: Int = previewLimit) -> (
        text: String, truncated: Bool
    ) {
        let truncated = data.count > limit
        let visible = truncated ? data.prefix(limit) : data[...]
        let text =
            String(data: Data(visible), encoding: .utf8)
            ?? String(data: Data(visible), encoding: .isoLatin1)
            ?? ""
        return (text, truncated)
    }

    public static func textPreview(_ text: String, limit: Int = previewLimit) -> (
        text: String, truncated: Bool
    ) {
        textPreview(Data(text.utf8), limit: limit)
    }

    public static func cacheURL(
        for entry: RemoteFileEntry, machineID: UUID, createDirectory: Bool = true
    ) throws -> URL {
        guard !entry.name.isEmpty, entry.name != ".", entry.name != "..",
            !entry.name.contains("\0"), (entry.name as NSString).lastPathComponent == entry.name
        else {
            throw RemoteFileOperationError.invalidCacheName(entry.name)
        }
        let input = Data("\(machineID.uuidString)\u{1F}\(entry.path)".utf8)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        let stamp = Int(entry.modified?.timeIntervalSince1970 ?? 0)
        let folder = MachinePaths.previewCacheDir
            .appendingPathComponent("\(digest)-\(stamp)-\(entry.sizeBytes)")
        let destination = folder.appendingPathComponent(entry.name)
        guard
            destination.deletingLastPathComponent().standardizedFileURL.path
                == folder.standardizedFileURL.path
        else {
            throw RemoteFileOperationError.invalidCacheName(entry.name)
        }
        if createDirectory {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return destination
    }

    public static func materialize(
        _ entry: RemoteFileEntry, machineID: UUID, isLocal: Bool,
        download: (String, URL) async throws -> Void
    ) async throws -> URL {
        if isLocal { return URL(fileURLWithPath: entry.path) }
        let destination = try cacheURL(for: entry, machineID: machineID)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try await self.download(remotePath: entry.path, to: destination, using: download)
        return destination
    }

    public static func download(
        remotePath: String, to destination: URL,
        using transfer: (String, URL) async throws -> Void
    ) async throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).edith-download-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try await transfer(remotePath, staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    public static func sweepCache(limitBytes: Int64 = 512 * 1024 * 1024) {
        let fileManager = FileManager.default
        let root = MachinePaths.previewCacheDir
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey])
        else { return }
        var sized: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for entry in entries {
            let files =
                (try? fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]))
                ?? []
            let size = files.reduce(Int64(0)) { sum, file in
                sum
                    + Int64(
                        (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            let accessed =
                (try? entry.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                ?? Date.distantPast
            sized.append((entry, accessed, size))
            total += size
        }
        guard total > limitBytes else { return }
        for (url, _, size) in sized.sorted(by: { $0.1 < $1.1 }) {
            try? fileManager.removeItem(at: url)
            total -= size
            if total <= limitBytes { break }
        }
    }

    @discardableResult
    public static func present(
        _ urls: [URL], action: FilePresentationAction,
        using presenter: ([URL], FilePresentationAction) -> Bool
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        return presenter(urls, action)
    }
}

public enum PortForwardBrowserOperationExecution {
    public static func url(forward: PortForward) -> URL? {
        LocalBrowserOperationExecution.url(port: forward.localPort)
    }
}

public enum LocalBrowserOperationExecution {
    public static func url(port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }

    public static func publishedPorts(
        in container: DockerContainer, matching requestedPort: Int?
    ) -> [DockerPortMapping] {
        container.ports.filter { port in
            guard port.browserURL != nil else { return false }
            guard let requestedPort else { return true }
            return port.hostPort == requestedPort || port.containerPort == requestedPort
        }
    }
}
