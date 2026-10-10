import EdithExtensionSupport
import Foundation

public enum ExtensionCLIContext {
    @TaskLocal public static var request: ExtensionCLIRequest?
    @TaskLocal public static var outputSink: (@Sendable (String, Bool) -> Void)?

    public static func resolvePath(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count <= 4_096,
            let request
        else { throw ExtensionPeerError.invalidRequest }
        return URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
        ).standardizedFileURL
    }
}
