import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor public enum HostSideloadCLI {
    public nonisolated static let usage = "usage: ed extensions sideload <package.zip|package directory> [--json]"

    public nonisolated static func stage(
        _ arguments: [String], workingDirectory: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> (arguments: [String], directory: URL) {
        let json = arguments.last == "--json"
        let words = json ? Array(arguments.dropLast()) : arguments
        guard words.count == 1, let path = words.first, !path.isEmpty else {
            throw HostCLIError.usage(usage)
        }
        let sideload: ExtensionSideload
        do {
            sideload = try ExtensionSideload(
                path: URL(
                    fileURLWithPath: path,
                    relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
                ).standardizedFileURL)
        } catch {
            throw HostCLIError.rejected(error.localizedDescription)
        }
        let directory = temporaryDirectory.appendingPathComponent(
            "edith-sideload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(sideload.archive.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sideload.archive, to: archive)
            try JSONEncoder().encode(sideload.package).write(
                to: archive.deletingPathExtension().appendingPathExtension("json"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ([archive.path] + (json ? ["--json"] : []), directory)
    }

    public static func execute(
        _ arguments: [String], marketplace: HostMarketplace, workingDirectory: String,
        admit: @escaping ExtensionPackageInstaller.Verify = HostMarketplace.adHocBundles
    ) async throws -> ExtensionCLIReply {
        var arguments = arguments
        let json = arguments.last == "--json"
        if json { arguments.removeLast() }
        guard arguments.count == 1, let path = arguments.first, !path.isEmpty else {
            throw HostCLIError.usage(usage)
        }
        let url = URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        ).standardizedFileURL
        let package: ExtensionPackage
        do {
            package = try await marketplace.sideload(ExtensionSideload(path: url), admit: admit)
        } catch let error as HostCLIError {
            throw error
        } catch {
            throw HostCLIError.rejected(error.localizedDescription)
        }
        let output =
            json
            ? String(
                decoding: try JSONSerialization.data(
                    withJSONObject: [
                        "id": package.id, "version": package.version, "hostABI": package.hostABI,
                        "running": marketplace.sessions.activeIDs.contains(package.id),
                    ], options: .sortedKeys), as: UTF8.self) + "\n"
            : "Sideloaded \(package.id) \(package.version) into this development build.\n"
        return try ExtensionCLIReply(stdout: output, stderr: "", exitCode: 0)
    }
}
