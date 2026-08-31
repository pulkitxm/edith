import EdithKit
import Foundation

struct LighthouseAuditResult: Sendable {
    let scores: SEOAuditScores
    let error: String?
}

struct LighthouseAuditor: Sendable {
    let executable: URL?
    let cacheDirectory: URL

    init(
        executable: URL? = CLIToolEnvironment.executable(named: "lighthouse"),
        cacheDirectory: URL = AppData.supportDir.appendingPathComponent(
            "Cache/SEOAudit", isDirectory: true)
    ) {
        self.executable = executable
        self.cacheDirectory = cacheDirectory
    }

    var isAvailable: Bool { executable != nil }

    func audit(_ url: URL) async -> LighthouseAuditResult {
        guard let executable else {
            return LighthouseAuditResult(
                scores: .unavailable,
                error:
                    "Install Lighthouse with npm install -g lighthouse, then run the audit again.")
        }
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: cacheDirectory, withIntermediateDirectories: true)
                let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: output) }
                let process = Process()
                let diagnostics = Pipe()
                process.executableURL = executable
                process.arguments = [
                    url.absoluteString,
                    "--output=json",
                    "--output-path=\(output.path)",
                    "--only-categories=performance,accessibility,best-practices,seo",
                    "--chrome-flags=--headless --no-sandbox --disable-gpu",
                    "--quiet",
                ]
                process.environment = CLIToolEnvironment.sanitized()
                process.standardError = diagnostics
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                let errorData = diagnostics.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    return LighthouseAuditResult(
                        scores: .unavailable,
                        error: message?.isEmpty == false
                            ? message
                            : "Lighthouse exited with status \(process.terminationStatus).")
                }
                let data = try Data(contentsOf: output)
                return LighthouseAuditResult(
                    scores: try Self.scores(from: data), error: nil)
            } catch {
                return LighthouseAuditResult(
                    scores: .unavailable, error: error.localizedDescription)
            }
        }.value
    }

    private static func scores(from data: Data) throws -> SEOAuditScores {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let categories = json?["categories"] as? [String: Any]
        return SEOAuditScores(
            performance: score("performance", in: categories),
            accessibility: score("accessibility", in: categories),
            bestPractices: score("best-practices", in: categories),
            seo: score("seo", in: categories))
    }

    private static func score(_ key: String, in categories: [String: Any]?) -> Int? {
        guard let category = categories?[key] as? [String: Any],
            let value = category["score"] as? Double
        else { return nil }
        return Int((value * 100).rounded())
    }
}
