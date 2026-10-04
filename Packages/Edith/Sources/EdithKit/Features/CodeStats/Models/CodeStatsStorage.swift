import Darwin
import Foundation

public enum CodeStatsStorageStatus: Codable, Equatable, Hashable, Sendable {
    case notConfigured
    case ready(freeBytes: Int64?)
    case volumeDisconnected(volumeName: String)
    case missing
    case notDirectory
    case notWritable

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct CodeStatsVolume: Equatable, Sendable {
    public let name: String
    public let mountPoint: String

    public init(name: String, mountPoint: String) {
        self.name = name
        self.mountPoint = mountPoint
    }
}

public enum CodeStatsFileEntry: Equatable, Sendable {
    case absent
    case file
    case directory
}

public struct CodeStatsFileProbe: Sendable {
    public var volume: @Sendable (String) -> CodeStatsVolume?
    public var isMounted: @Sendable (CodeStatsVolume) -> Bool
    public var entry: @Sendable (String) -> CodeStatsFileEntry
    public var isWritable: @Sendable (String) -> Bool
    public var freeBytes: @Sendable (String) -> Int64?

    public init(
        volume: @escaping @Sendable (String) -> CodeStatsVolume?,
        isMounted: @escaping @Sendable (CodeStatsVolume) -> Bool,
        entry: @escaping @Sendable (String) -> CodeStatsFileEntry,
        isWritable: @escaping @Sendable (String) -> Bool,
        freeBytes: @escaping @Sendable (String) -> Int64?
    ) {
        self.volume = volume
        self.isMounted = isMounted
        self.entry = entry
        self.isWritable = isWritable
        self.freeBytes = freeBytes
    }

    public static func externalVolume(of path: String) -> CodeStatsVolume? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else {
            return nil
        }
        return CodeStatsVolume(name: components[2], mountPoint: "/Volumes/" + components[2])
    }

    public static let live = CodeStatsFileProbe(
        volume: { externalVolume(of: $0) },
        isMounted: { volume in
            let resolved = URL(fileURLWithPath: volume.mountPoint).resolvingSymlinksInPath().path
            var mount = stat()
            var parent = stat()
            guard stat(resolved, &mount) == 0 else { return false }
            if externalVolume(of: resolved) == nil { return true }
            guard stat("/Volumes", &parent) == 0 else { return false }
            return mount.st_dev != parent.st_dev
        },
        entry: { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .absent
            }
            return isDirectory.boolValue ? .directory : .file
        },
        isWritable: { FileManager.default.isWritableFile(atPath: $0) },
        freeBytes: { path in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            return values?.volumeAvailableCapacityForImportantUsage
        })
}

public enum CodeStatsStorageEvaluator {
    public static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    public static func status(
        for path: String?, probe: CodeStatsFileProbe = .live
    ) -> CodeStatsStorageStatus {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .notConfigured
        }
        let folder = standardized(path)
        if let volume = probe.volume(folder), !probe.isMounted(volume) {
            return .volumeDisconnected(volumeName: volume.name)
        }
        switch probe.entry(folder) {
        case .absent: return .missing
        case .file: return .notDirectory
        case .directory:
            guard probe.isWritable(folder) else { return .notWritable }
            return .ready(freeBytes: probe.freeBytes(folder))
        }
    }
}
