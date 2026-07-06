import Foundation

@MainActor
enum StandupBinaryLocator {
    private static var cache: [String: String] = [:]

    static func resolve(_ name: String) async -> String? {
        if let cached = cache[name] { return cached.isEmpty ? nil : cached }
        let resolved = await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lic", "which \(name)"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, let path, !path.isEmpty else { return nil }
            return path
        }.value
        cache[name] = resolved ?? ""
        return resolved
    }
}
