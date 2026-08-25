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
    case fileTooLarge(String, Int64, Int64)
    case cacheBudgetExceeded(Int64)

    public var errorDescription: String? {
        switch self {
        case let .invalidCacheName(name):
            return "The remote file name cannot be cached safely: \(name)"
        case let .fileTooLarge(name, size, maximum):
            return
                "\(name) is \(ByteFormatter.string(size)), which exceeds the "
                + "\(ByteFormatter.string(maximum)) preview limit. Download it instead."
        case let .cacheBudgetExceeded(maximum):
            return
                "The remote preview cache could not make \(ByteFormatter.string(maximum)) "
                + "available. Download the file instead."
        }
    }
}

public enum RemoteAutomaticPreviewDecision: Equatable, Sendable {
    case automatic
    case requiresExplicitDownload
    case downloadOnly
}

public enum RemoteFileOperationExecution {
    public static let previewLimit = 400 * 1024
    public static let automaticPreviewLimitBytes: Int64 = 64 * 1024 * 1024
    public static let cacheLimitBytes: Int64 = 512 * 1024 * 1024

    public static func automaticPreviewDecision(
        for entry: RemoteFileEntry, isLocal: Bool
    ) -> RemoteAutomaticPreviewDecision {
        guard !isLocal else { return .automatic }
        if entry.sizeBytes <= automaticPreviewLimitBytes { return .automatic }
        if entry.sizeBytes <= cacheLimitBytes { return .requiresExplicitDownload }
        return .downloadOnly
    }

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
        for entry: RemoteFileEntry, machineID: UUID, createDirectory: Bool = true,
        root: URL = MachinePaths.previewCacheDir
    ) throws -> URL {
        guard !entry.name.isEmpty, entry.name != ".", entry.name != "..",
            !entry.name.contains("\0"), (entry.name as NSString).lastPathComponent == entry.name
        else {
            throw RemoteFileOperationError.invalidCacheName(entry.name)
        }
        let input = Data("\(machineID.uuidString)\u{1F}\(entry.path)".utf8)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        let stamp = Int(entry.modified?.timeIntervalSince1970 ?? 0)
        let folder =
            root
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
        maximumBytes: Int64 = cacheLimitBytes, cacheLimit: Int64 = cacheLimitBytes,
        cacheRoot: URL = MachinePaths.previewCacheDir,
        download: (String, URL) async throws -> Void
    ) async throws -> URL {
        if isLocal { return URL(fileURLWithPath: entry.path) }
        guard entry.sizeBytes <= maximumBytes else {
            throw RemoteFileOperationError.fileTooLarge(
                entry.name, entry.sizeBytes, maximumBytes)
        }
        let destination = try cacheURL(
            for: entry, machineID: machineID, createDirectory: false, root: cacheRoot)
        if entry.modified != nil,
            FileManager.default.fileExists(atPath: destination.path),
            cachedFileMatches(entry, at: destination)
        {
            await RemotePreviewCacheCoordinator.shared.touch(
                destination: destination, root: cacheRoot, limitBytes: cacheLimit)
            return destination
        }
        let reservation = try await RemotePreviewCacheCoordinator.shared.reserve(
            destination: destination, expectedBytes: entry.sizeBytes, root: cacheRoot,
            limitBytes: cacheLimit)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await self.download(remotePath: entry.path, to: destination, using: download)
            let actualBytes = cachedFileSize(at: destination)
            guard actualBytes <= maximumBytes else {
                try? FileManager.default.removeItem(at: destination)
                throw RemoteFileOperationError.fileTooLarge(
                    entry.name, actualBytes, maximumBytes)
            }
            try await RemotePreviewCacheCoordinator.shared.finish(
                reservation, actualBytes: actualBytes)
            return destination
        } catch {
            await RemotePreviewCacheCoordinator.shared.cancel(reservation)
            throw error
        }
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

    @discardableResult
    public static func present(
        _ urls: [URL], action: FilePresentationAction,
        using presenter: ([URL], FilePresentationAction) -> Bool
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        return presenter(urls, action)
    }

    private static func cachedFileMatches(_ entry: RemoteFileEntry, at destination: URL) -> Bool {
        entry.sizeBytes <= 0 || cachedFileSize(at: destination) == entry.sizeBytes
    }

    private static func cachedFileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

private actor RemotePreviewCacheCoordinator {
    static let shared = RemotePreviewCacheCoordinator()

    struct Reservation: Sendable {
        let id: UUID
        let destination: URL
        let root: URL
        let expectedBytes: Int64
        let limitBytes: Int64
    }

    private var reservations: [UUID: Reservation] = [:]

    func reserve(
        destination: URL, expectedBytes: Int64, root: URL, limitBytes: Int64
    ) throws -> Reservation {
        let expectedBytes = max(0, expectedBytes)
        guard expectedBytes <= limitBytes else {
            throw RemoteFileOperationError.cacheBudgetExceeded(limitBytes)
        }
        let reserved = reservations.values
            .filter { $0.root.standardizedFileURL == root.standardizedFileURL }
            .reduce(Int64(0)) { $0 + $1.expectedBytes }
        let target = limitBytes - reserved - expectedBytes
        let protected = Set(
            reservations.values
                .filter { $0.root.standardizedFileURL == root.standardizedFileURL }
                .map { $0.destination.deletingLastPathComponent().standardizedFileURL }
                + [destination.deletingLastPathComponent().standardizedFileURL])
        guard evict(root: root, targetBytes: target, protecting: protected) else {
            throw RemoteFileOperationError.cacheBudgetExceeded(limitBytes)
        }
        let reservation = Reservation(
            id: UUID(), destination: destination, root: root,
            expectedBytes: expectedBytes, limitBytes: limitBytes)
        reservations[reservation.id] = reservation
        return reservation
    }

    func finish(_ reservation: Reservation, actualBytes: Int64) throws {
        reservations[reservation.id] = nil
        guard actualBytes <= reservation.limitBytes else {
            try? FileManager.default.removeItem(at: reservation.destination)
            throw RemoteFileOperationError.cacheBudgetExceeded(reservation.limitBytes)
        }
        let outstanding = reservations.values
            .filter { $0.root.standardizedFileURL == reservation.root.standardizedFileURL }
        let protected = Set(
            outstanding.map { $0.destination.deletingLastPathComponent().standardizedFileURL }
                + [reservation.destination.deletingLastPathComponent().standardizedFileURL])
        let reservedBytes = outstanding.reduce(Int64(0)) { $0 + $1.expectedBytes }
        guard
            evict(
                root: reservation.root, targetBytes: reservation.limitBytes - reservedBytes,
                protecting: protected)
        else {
            try? FileManager.default.removeItem(at: reservation.destination)
            throw RemoteFileOperationError.cacheBudgetExceeded(reservation.limitBytes)
        }
        touchFolder(for: reservation.destination)
    }

    func cancel(_ reservation: Reservation) {
        reservations[reservation.id] = nil
    }

    func touch(destination: URL, root: URL, limitBytes: Int64) {
        touchFolder(for: destination)
        _ = evict(
            root: root, targetBytes: limitBytes,
            protecting: [destination.deletingLastPathComponent().standardizedFileURL])
    }

    private func evict(root: URL, targetBytes: Int64, protecting: Set<URL>) -> Bool {
        guard targetBytes >= 0 else { return false }
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey])
        else { return true }
        var sized: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for entry in entries {
            let files =
                (try? manager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(Int64(0)) { sum, file in
                sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            let accessed =
                (try? entry.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                ?? Date.distantPast
            sized.append((entry, accessed, size))
            total += size
        }
        if total <= targetBytes { return true }
        for (url, _, size) in sized.sorted(by: { $0.1 < $1.1 })
        where !protecting.contains(url.standardizedFileURL) {
            do {
                try manager.removeItem(at: url)
                total -= size
            } catch {}
            if total <= targetBytes { return true }
        }
        return total <= targetBytes
    }

    private func touchFolder(for destination: URL) {
        var folder = destination.deletingLastPathComponent()
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? folder.setResourceValues(values)
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
