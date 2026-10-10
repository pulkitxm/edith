import EdithExtensionSupport
import Foundation

public enum HostCLIErrorReply {
    public static func make(_ error: Error) -> ExtensionCLIReply {
        if let failure = error as? HostCoreCommandFailure { return try! failure.reply() }
        let failure = error as? HostCLIError
        var code = failure?.exitCode ?? (error is CancellationError ? 130 : 1)
        if case .unavailable = failure { code = 4 }
        return try! ExtensionCLIReply(
            stdout: "", stderr: "error: \(String(error.localizedDescription.prefix(4096)))\n",
            exitCode: code)
    }
}
