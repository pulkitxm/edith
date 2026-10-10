import EdithExtensionSupport
import Foundation

struct MachineCLIInput: Codable, Sendable {
    var arguments: [String]
    var standardInput: Data?
    var terminalSession: String?

    func validate() throws {
        try ExtensionCLIRequest(arguments: arguments).validate()
        guard standardInput.map({ $0.count <= 1_048_576 }) ?? true,
            terminalSession.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) })
                ?? true
        else { throw ExtensionPeerError.invalidRequest }
    }
}

public enum MachineCLIContext {
    @TaskLocal public static var input: Data?
    @TaskLocal public static var terminalSession: String?
}
