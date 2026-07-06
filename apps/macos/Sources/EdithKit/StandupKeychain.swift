import Foundation

public enum StandupKeychain {
    private static let service = "com.pulkit.edith.standup"
    private static let account = "notion-token"

    public static func set(_ token: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
        guard !token.isEmpty else { return }
        _ = run(["add-generic-password", "-U", "-s", service, "-a", account, "-w", token])
    }

    public static func get() -> String? {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (-1, "") }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
