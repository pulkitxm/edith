import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor public enum HostSideloadCLI {
    public static let usage = "usage: ed extensions sideload <package.zip|package directory> [--json]"

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
