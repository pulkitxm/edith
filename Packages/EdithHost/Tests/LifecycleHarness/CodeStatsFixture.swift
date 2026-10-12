import CryptoKit
import EdithExtensionSupport
import Foundation
import ImageIO

@MainActor enum CodeStatsFixture {
    private static var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]!)
            .appendingPathComponent("Synthetic Repositories")
    }

    static func seed() throws {
        let repository = folder.appendingPathComponent("example/synthetic")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], directory: repository)
        guard try git(["remote"], directory: repository).isEmpty else {
            throw ExtensionPeerError.invalidRequest
        }
        for value in [1, 2] {
            try "func fixtureValue() -> Int { \(value) }\n".write(
                to: repository.appendingPathComponent("Fixture.swift"), atomically: true,
                encoding: .utf8)
            try git(["add", "Fixture.swift"], directory: repository)
            try git(
                ["commit", "-q", "-m", "Synthetic fixture value \(value)"], directory: repository)
        }
    }

    static func verify(_ endpoint: ExtensionPeerEndpoint, initialize: Bool) async throws {
        if initialize {
            _ = try await call(
                endpoint, "codeStats.folder", ["path": folder.path, "confirm": true])
            _ = try await call(
                endpoint, "codeStats.identity.add", ["value": "fixture@example.invalid"])
            _ = try await call(endpoint, "codeStats.schedule", ["kind": "manual"])
            let run = try await call(endpoint, "codeStats.run", [:])
            guard run["taskID"] is String else { throw failure("run admission") }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var completed = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                let status = try await call(endpoint, "codeStats.status", [:])
                if let state = status["state"] as? [String: Any], state["active"] == nil,
                    let last = state["lastRun"] as? [String: Any],
                    let outcome = last["outcome"] as? [String: Any], outcome["completed"] != nil
                {
                    completed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard completed else { throw failure("analysis completion") }
        }
        let report = try await call(endpoint, "codeStats.report", ["range": "all"])
        guard let totals = report["totals"] as? [String: Any], totals["commits"] as? Int == 2,
            totals["repositories"] as? Int == 1,
            let repositories = report["repositories"] as? [[String: Any]],
            repositories.map({ $0["repository"] as? String }) == ["example/synthetic"]
        else { throw failure("report: \(report)") }
        let snapshot = try JSONDecoder().decode(
            SurfaceSnapshot.self,
            from: await endpoint.invoke(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.codeStats))
                    .encoded(
                        providerID: "codeStats")))
        guard snapshot.rows.contains(where: { $0.sourceID == "example/synthetic" }),
            snapshot.metrics.contains(where: { $0.id == "commits" && $0.value == "2" })
        else { throw failure("surface: \(snapshot)") }
        let image = try await call(
            endpoint, "codeStats.export", ["range": "all", "card": "highlights"])
        var exported = image
        if let resultID = image["resultID"] as? String,
            let byteCount = image["byteCount"] as? Int,
            let expectedHash = image["sha256"] as? String
        {
            guard (1...64_000_000).contains(byteCount), UUID(uuidString: resultID) != nil else {
                throw failure("export receipt")
            }
            var result = Data()
            while result.count < byteCount {
                let chunk = try await call(
                    endpoint, "codeStats.result.chunk",
                    ["resultID": resultID, "offset": result.count])
                guard chunk["offset"] as? Int == result.count,
                    let encoded = chunk["data"] as? String,
                    let bytes = Data(base64Encoded: encoded),
                    !bytes.isEmpty, bytes.count <= 262_144,
                    bytes.count <= byteCount - result.count,
                    chunk["finished"] as? Bool == (result.count + bytes.count == byteCount)
                else { throw failure("export chunk") }
                result.append(bytes)
            }
            guard
                SHA256.hash(data: result).map({ String(format: "%02x", $0) }).joined()
                    == expectedHash,
                let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            else { throw failure("export integrity") }
            exported = object
        }
        guard exported["filename"] as? String == "edith-code-stats-highlights.png",
            let encoded = exported["data"] as? String, let bytes = Data(base64Encoded: encoded),
            bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
            let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width > 100,
            decoded.height > 100
        else { throw failure("PNG export") }
        do {
            _ = try await call(endpoint, "codeStats.folder", ["path": "/", "confirm": true])
            throw ExtensionPeerError.invalidRequest
        } catch ExtensionPeerError.invalidRequest { throw ExtensionPeerError.invalidRequest } catch
        {}
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CodeStatsFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func call(
        _ endpoint: ExtensionPeerEndpoint, _ command: String, _ input: [String: Any]
    ) async throws -> [String: Any] {
        let bytes = try await endpoint.invoke(
            command, payload: JSONSerialization.data(withJSONObject: input), timeout: 20)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ExtensionPeerError.invalidRequest
        }
        return object
    }

    @discardableResult
    private static func git(_ arguments: [String], directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": folder.deletingLastPathComponent().path,
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Synthetic Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Synthetic Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtensionPeerError.invalidRequest }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}
