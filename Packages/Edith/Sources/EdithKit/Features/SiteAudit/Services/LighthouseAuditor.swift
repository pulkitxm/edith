import Foundation

public struct LighthouseAuditResult: Sendable {
    public let scores: SEOAuditScores
    public let error: String?
}

public struct LighthouseAuditor: Sendable {
    public let executable: URL?
    public let cacheDirectory: URL

    public init(
        executable: URL? = CLIToolEnvironment.executable(named: "lighthouse"),
        cacheDirectory: URL = AppData.supportDir.appendingPathComponent(
            "Cache/SEOAudit", isDirectory: true)
    ) {
        self.executable = executable
        self.cacheDirectory = cacheDirectory
    }

    public var isAvailable: Bool { executable != nil }

    public func audit(_ url: URL) async -> LighthouseAuditResult {
        guard let executable else {
            return LighthouseAuditResult(
                scores: .unavailable,
                error:
                    "Install Lighthouse with npm install -g lighthouse, then run the audit again.")
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await CLICommandRunner.run(
                CLICommandRequest(
                    executableURL: executable,
                    arguments: [
                        url.absoluteString,
                        "--output=json",
                        "--output-path=\(output.path)",
                        "--only-categories=performance,accessibility,best-practices,seo",
                        "--chrome-flags=--headless --no-sandbox --disable-gpu",
                        "--quiet",
                    ], environment: CLIToolEnvironment.sanitized(), timeout: 180,
                    maximumOutputBytes: 1_000_000, terminatesProcessGroup: true
                ), onLine: { _ in })
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.terminationStatus == 0 else {
                return LighthouseAuditResult(
                    scores: .unavailable,
                    error: message.isEmpty
                        ? "Lighthouse exited with status \(result.terminationStatus)." : message)
            }
            let data = try Data(contentsOf: output)
            return LighthouseAuditResult(scores: try Self.scores(from: data), error: nil)
        } catch CLICommandRunnerError.timedOut {
            return LighthouseAuditResult(
                scores: .unavailable, error: "Lighthouse timed out after three minutes.")
        } catch CLICommandRunnerError.outputLimitExceeded {
            return LighthouseAuditResult(
                scores: .unavailable, error: "Lighthouse produced too much diagnostic output.")
        } catch {
            return LighthouseAuditResult(scores: .unavailable, error: error.localizedDescription)
        }
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
