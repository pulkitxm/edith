import Foundation

public enum AutomationCommandProcessError: LocalizedError {
    case failed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .failed(let status, let output):
            output.isEmpty ? "The operation exited with status \(status)." : output
        }
    }
}

public enum AutomationCommandProcess {
    public static func run(executable: URL, arguments: [String]) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = {
                    continuation.resume(returning: $0.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try output.synchronize()
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw AutomationCommandProcessError.failed(status, text) }
        return text
    }
}
