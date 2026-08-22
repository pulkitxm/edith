import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIAttentionTests {
    @Test func rangeParserSupportsHumanAndCompactWindows() throws {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        #expect(try AttentionCLI.interval("24h", now: now).duration == 86_400)
        #expect(try AttentionCLI.interval("2w", now: now).duration == 1_209_600)
        #expect(try AttentionCLI.duration("25m") == 1_500)
        #expect(try AttentionCLI.duration("1.5h") == 5_400)
    }

    @Test func emptyStatusAndSummaryAreValidJSON() async throws {
        await CLIProbe.inWorld { _ in
            let status = await CLIProbe.capture(["attention", "status", "--json"])
            #expect(status.code == 0)
            #expect(status.object?["eventsLast24Hours"] as? Int == 0)
            let summary = await CLIProbe.capture([
                "attention", "summary", "--range", "7d", "--json",
            ])
            #expect(summary.code == 0)
            #expect(summary.object?["activeSeconds"] as? Int == 0)
            #expect((summary.object?["entities"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func categorizingEntityImmediatelyReclassifiesHistory() async throws {
        try await CLIProbe.inWorld { world in
            let repository = AttentionRepository(root: world.sandbox)
            let now = Date()
            try repository.append(
                AttentionEvent(
                    startedAt: now.addingTimeInterval(-600), duration: 300,
                    source: .application, appName: "Writing", bundleID: "com.example.Writing"))
            let command = await CLIProbe.capture([
                "attention", "categories", "set", "app:com.example.Writing", "focus",
                "--name", "Writing", "--json",
            ])
            #expect(command.code == 0)
            #expect(command.object?["categoryID"] as? String == "focus")
            let summary = await CLIProbe.capture([
                "attention", "summary", "--range", "24h", "--json",
            ])
            #expect(summary.code == 0)
            #expect((summary.object?["focusedSeconds"] as? NSNumber)?.doubleValue == 300)
        }
    }

    @Test func focusLifecycleWorksWithoutTheAppRunning() async throws {
        await CLIProbe.inWorld { _ in
            let start = await CLIProbe.capture([
                "attention", "focus", "start", "--for", "25m", "--name", "Draft", "--json",
            ])
            #expect(start.code == 0)
            #expect(start.object?["plannedSeconds"] as? Int == 1_500)
            let status = await CLIProbe.capture(["attention", "focus", "status", "--json"])
            #expect(status.object?["name"] as? String == "Draft")
            let stop = await CLIProbe.capture(["attention", "focus", "stop", "--json"])
            #expect(stop.code == 0)
            #expect(stop.object?["endedAt"] is String)
        }
    }

    @Test func statusAndDoctorCheckTheLiveBrowserServer() async throws {
        try await CLIProbe.inWorld { world in
            let repository = AttentionRepository(root: world.sandbox)
            try repository.saveSettings(
                AttentionSettings(isEnabled: true, browserTrackingEnabled: true, serverPort: 0))

            let status = await CLIProbe.capture(["attention", "status", "--json"])
            #expect(status.object?["enabled"] as? Bool == true)
            #expect(status.object?["browserTrackingEnabled"] as? Bool == true)
            #expect(status.object?["browserServerReady"] as? Bool == false)

            let doctor = await CLIProbe.capture(["attention", "doctor", "--json"])
            #expect(doctor.object?["ok"] as? Bool == false)
            let checks = doctor.object?["checks"] as? [[String: Any]]
            let browser = checks?.first { $0["name"] as? String == "browser tracking" }
            #expect(browser?["ok"] as? Bool == false)
            #expect(
                browser?["detail"] as? String == "enabled but local server is unavailable")
        }
    }
}
