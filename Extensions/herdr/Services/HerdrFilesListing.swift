import EdithExtensionSupport
import Foundation

struct HerdrFilesHomeReply: Codable, Equatable {
    let path: String
}

struct HerdrFilesListReply: Codable, Equatable {
    let entries: [RemoteFileEntry]
}

enum HerdrFilesListing {
    static let timeout: TimeInterval = 20
    static let entryLimit = 1_500

    static func home(on machine: Machine) async throws -> String {
        guard machine.id != Machine.localID else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        let platform = await connection.remotePlatform ?? .linux
        let result = try await connection.run(
            FilePlaces.homeDirectoryCommand(platform: platform), timeout: timeout)
        let home = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") || FileListing.isWindowsPath(home) else {
            throw HerdrCommandError.malformedResponse
        }
        return home
    }

    static func list(_ path: String, on machine: Machine) async throws -> [RemoteFileEntry] {
        let entries =
            machine.id == Machine.localID
            ? try local(path) : try await remote(path, on: machine)
        return Array(entries.prefix(entryLimit))
    }

    private static func remote(_ path: String, on machine: Machine) async throws
        -> [RemoteFileEntry]
    {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        let platform = await connection.remotePlatform ?? .linux
        let result = try await connection.run(
            FileListing.command(path: path, platform: platform), timeout: timeout)
        return FileListing.parse(output: result.stdoutText, parent: path)
    }

    private static func local(_ path: String) throws -> [RemoteFileEntry] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let urls = try manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [])
        let entries = urls.map { url -> RemoteFileEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let symlink = values?.isSymbolicLink == true
            let directory =
                symlink
                ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                : values?.isDirectory == true
            let kind: FileEntryKind = directory ? .directory : (symlink ? .symlink : .file)
            return RemoteFileEntry(
                name: url.lastPathComponent,
                path: FileListing.join(parent: path, name: url.lastPathComponent), kind: kind,
                sizeBytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                linkTarget: symlink
                    ? try? manager.destinationOfSymbolicLink(atPath: url.path) : nil)
        }
        return FileListing.sorted(entries)
    }
}

extension HerdrFilesSource {
    static func direct(on machine: Machine) -> HerdrFilesSource {
        HerdrFilesSource(
            home: { try await HerdrFilesListing.home(on: machine) },
            list: { try await HerdrFilesListing.list($0, on: machine) })
    }
}
