import CryptoKit
import EdithExtensionSupport
import EdithHostCore
import Foundation

extension HostLifecycleHarness {
    static func prepareUsageFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"],
            !path.isEmpty,
            URL(fileURLWithPath: path).standardizedFileURL
                != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        else { throw HostWorkerError.rejected }
        let home = URL(fileURLWithPath: path, isDirectory: true)
        let receipts = home.appendingPathComponent(".claude/projects/sample", isDirectory: true)
        let project = home.appendingPathComponent("synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let receipt: [String: Any] = [
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sessionId": "synthetic-session", "requestId": "synthetic-request",
            "cwd": project.path, "costUSD": 1,
            "message": [
                "id": "synthetic-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 10, "output_tokens": 2],
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: receipt)
        data.append(10)
        try data.write(to: receipts.appendingPathComponent("session.jsonl"), options: .atomic)
    }

    @MainActor static func verifyUsage(_ endpoint: ExtensionPeerEndpoint, restored: Bool)
        async throws
    {
        func object(_ command: String, _ input: [String: Any] = [:]) async throws -> Any {
            let data = try await endpoint.invoke(
                command, payload: JSONSerialization.data(withJSONObject: input), timeout: 5)
            return try JSONSerialization.jsonObject(with: data)
        }
        func verifySummary() async throws {
            let summary = try await object("usage.summary", ["days": 30]) as? [String: Any]
            guard let period = summary?["period"] as? [String: Any],
                period["tokens"] as? Double == 12, period["cost"] as? Double == 1,
                summary?["activeDays"] as? Int == 1
            else { throw HostWorkerError.invalidResponse }
        }
        if restored { try await verifySummary() }
        let refresh = try await object("usage.refresh", ["machinePolicy": "skip"]) as? [String: Any]
        guard let runID = refresh?["runID"] as? String, UUID(uuidString: runID) != nil else {
            throw HostWorkerError.invalidResponse
        }
        let deadline = Date().addingTimeInterval(20)
        while true {
            let status = try await object("usage.status") as? [String: Any]
            guard status?["failure"] is NSNull, let refreshing = status?["refreshing"] as? Bool
            else { throw HostWorkerError.invalidResponse }
            if !refreshing { break }
            guard Date() < deadline else { throw HostWorkerError.invalidResponse }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await verifySummary()
        let sources = try await object("usage.sources") as? [[String: Any]]
        guard let sources, !sources.isEmpty,
            sources.allSatisfy({ $0["id"] is String && $0["title"] is String })
        else { throw HostWorkerError.invalidResponse }
        let image =
            try await object("usage.share", ["card": "highlights", "days": 30])
            as? [String: Any]
        guard let filename = image?["filename"] as? String, filename.hasSuffix(".png"),
            !filename.contains("/"), let encoded = image?["data"] as? String,
            let png = Data(base64Encoded: encoded), png.count <= 4_194_304,
            png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        else { throw HostWorkerError.invalidResponse }
        let exported = try await object("usage.history.export") as? [String: Any]
        guard let exportID = exported?["exportID"] as? String, UUID(uuidString: exportID) != nil,
            let byteCount = exported?["byteCount"] as? Int, (1...67_108_864).contains(byteCount),
            let checksum = exported?["sha256"] as? String
        else { throw HostWorkerError.invalidResponse }
        var history = Data()
        while history.count < byteCount {
            let chunk =
                try await object(
                    "usage.history.chunk", ["exportID": exportID, "offset": history.count])
                as? [String: Any]
            guard chunk?["offset"] as? Int == history.count,
                let encoded = chunk?["data"] as? String, let data = Data(base64Encoded: encoded),
                (1...262_144).contains(data.count), history.count + data.count <= byteCount,
                chunk?["finished"] as? Bool == (history.count + data.count == byteCount)
            else { throw HostWorkerError.invalidResponse }
            history.append(data)
        }
        guard SHA256.hash(data: history).map({ String(format: "%02x", $0) }).joined() == checksum,
            let document = try JSONSerialization.jsonObject(with: history) as? [String: Any],
            let daily = document["daily"] as? [Any], !daily.isEmpty
        else { throw HostWorkerError.invalidResponse }
        for (command, input) in [
            ("usage.refresh", ["path": "/synthetic/disallowed"]),
            ("usage.summary", ["days": 366]),
            ("usage.history.export", ["path": "/synthetic/disallowed"]),
            ("usage.history.chunk", ["exportID": exportID, "offset": 0]),
            ("usage.share", ["card": "highlights", "path": "/synthetic/disallowed"]),
        ] as [(String, [String: Any])] {
            do {
                _ = try await object(command, input)
                throw HostWorkerError.invalidResponse
            } catch is ExtensionPeerError {}
        }
    }
}
