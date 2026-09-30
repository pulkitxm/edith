import Darwin
import EdithKit
import Foundation

final class CLINativeDiagnostics {
    let protocolHandle: FileHandle
    private let errorDescriptor: Int32
    private let diagnosticsURL: URL

    init(url: URL, errorDescriptor: Int32 = STDERR_FILENO) throws {
        let saved = dup(errorDescriptor)
        guard saved >= 0 else { throw POSIXError(.EBADF) }
        let destination = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard destination >= 0 else {
            Darwin.close(saved)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(destination) }
        guard dup2(destination, errorDescriptor) >= 0 else {
            Darwin.close(saved)
            throw POSIXError(.EBADF)
        }
        self.errorDescriptor = errorDescriptor
        diagnosticsURL = url
        protocolHandle = FileHandle(fileDescriptor: saved, closeOnDealloc: true)
    }

    static func forCommand(json: Bool) throws -> CLINativeDiagnostics? {
        guard json, ProcessInfo.processInfo.environment["EDITH_CLI"] == "1" else { return nil }
        try FileManager.default.createDirectory(
            at: DataRoot.logs, withIntermediateDirectories: true)
        return try CLINativeDiagnostics(
            url: DataRoot.logs.appendingPathComponent("native-render-\(UUID().uuidString).log"))
    }

    deinit {
        dup2(protocolHandle.fileDescriptor, errorDescriptor)
        if (try? diagnosticsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            try? FileManager.default.removeItem(at: diagnosticsURL)
        }
    }
}
