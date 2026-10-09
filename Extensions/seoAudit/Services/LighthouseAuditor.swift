import EdithExtensionSupport
import Foundation

struct LighthouseAuditResult: Sendable {
    let scores: SEOAuditScores
    let error: String?
}

struct LighthouseAuditor: Sendable {
    static let installHint =
        "Install Lighthouse with npm install -g lighthouse, then run the audit again."
    static let maximumReportBytes = 16 * 1_024 * 1_024

    let locate: @Sendable () -> URL?
    let cacheDirectory: URL
    let run: @Sendable (CLICommandRequest) async throws -> CLICommandResult

    init(
        locate: @escaping @Sendable () -> URL? = {
            CLIToolEnvironment.executable(named: "lighthouse")
        },
        cacheDirectory: URL = ExtensionData.root.appendingPathComponent(
            "Cache/SEOAudit", isDirectory: true),
        run: @escaping @Sendable (CLICommandRequest) async throws -> CLICommandResult = {
            try await CLICommandRunner.run($0, onLine: { _ in })
        }
    ) {
        self.locate = locate
        self.cacheDirectory = cacheDirectory
        self.run = run
    }

    func isAvailable() async -> Bool {
        let locate = locate
        return await BlockingWork.value { locate() != nil }
    }

    func audit(_ url: URL) async -> LighthouseAuditResult {
        let locate = locate
        guard let executable = await BlockingWork.value({ locate() }) else {
            return LighthouseAuditResult(scores: .unavailable, error: Self.installHint)
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            let output = cacheDirectory.appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await run(
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
                    maximumOutputBytes: 1_000_000, terminatesProcessGroup: true))
            try Task.checkCancellation()
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.terminationStatus == 0 else {
                return LighthouseAuditResult(
                    scores: .unavailable,
                    error: message.isEmpty
                        ? "Lighthouse exited with status \(result.terminationStatus)."
                        : String(message.prefix(4_000)))
            }
            return LighthouseAuditResult(scores: try Self.scores(fromReport: output), error: nil)
        } catch is CancellationError {
            return LighthouseAuditResult(scores: .unavailable, error: "Lighthouse was cancelled.")
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

    static func scores(fromReport url: URL) throws -> SEOAuditScores {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
            size <= maximumReportBytes
        else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumReportBytes + 1) ?? Data()
        guard data.count <= maximumReportBytes else { throw CocoaError(.fileReadTooLarge) }
        return try scores(from: data)
    }

    static func scores(from data: Data) throws -> SEOAuditScores {
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
            let value = category["score"] as? Double, value.isFinite, (0...1).contains(value)
        else { return nil }
        return Int((value * 100).rounded())
    }
}
