import Foundation
import Testing

@testable import EdithKit

@Suite struct NetworkDiagnosticsTests {
    @Test func configurationClampsAndFiltersUnsafeValues() {
        let configuration = NetworkDiagnosticsConfiguration(
            targetHost: " example.com ",
            serviceTargets: [
                NetworkServiceTarget(host: "example.com", port: 443),
                NetworkServiceTarget(host: "", port: 0),
            ], exclusions: [" Internal.Example "], sampleIntervalMinutes: 1,
            timeoutSeconds: 100, retries: 10, pingCount: 0, timelineLimit: 2
        ).normalized

        #expect(configuration.targetHost == "example.com")
        #expect(configuration.serviceTargets.count == 1)
        #expect(configuration.exclusions == ["internal.example"])
        #expect(configuration.sampleIntervalMinutes == 5)
        #expect(configuration.timeoutSeconds == 30)
        #expect(configuration.retries == 3)
        #expect(configuration.pingCount == 1)
        #expect(configuration.timelineLimit == 10)
        #expect(configuration.excludes("api.internal.example"))
    }

    @Test func reportsRedactAddressesCredentialsQueriesAndSecrets() {
        let snapshot = NetworkDiagnosticSnapshot(
            durationMS: 10, state: .healthy,
            path: NetworkPathSummary(
                interfaceName: "en0", localAddress: "192.168.1.24", gateway: "192.168.1.1",
                dnsServers: ["1.1.1.1"], wifiName: "Private Home", wifiBSSID: "aa:bb:cc:dd:ee:ff",
                publicAddress: "203.0.113.10"),
            checks: [
                NetworkDiagnosticCheck(
                    id: "web", title: "HTTPS", state: .healthy, summary: "Connected",
                    detail: "https://user:pass@example.com/path?token=hello api_key=world")
            ])
        let report = NetworkDiagnosticsRedactor.report(snapshot)

        #expect(!report.contains("192.168"))
        #expect(!report.contains("1.1.1.1"))
        #expect(!report.contains("Private Home"))
        #expect(!report.contains("pass"))
        #expect(!report.contains("hello"))
        #expect(!report.contains("world"))
        #expect(report.contains("<address>"))
        #expect(report.contains("<redacted>"))
    }

    @Test func redactionPreservesTimestampsAndRedactsCompressedIPv6() {
        let text = "captured 2026-08-29T21:41:42Z from 2001:db8::1 and ::1"
        let redacted = NetworkDiagnosticsRedactor.redact(text)

        #expect(redacted.contains("2026-08-29T21:41:42Z"))
        #expect(!redacted.contains("2001:db8::1"))
        #expect(!redacted.contains("::1"))
    }

    @Test func baselineComparisonExplainsStateAndLatencyChanges() {
        let baseline = snapshot(
            check: NetworkDiagnosticCheck(
                id: "dns", title: "DNS", state: .healthy, summary: "Resolved", durationMS: 20))
        let current = snapshot(
            check: NetworkDiagnosticCheck(
                id: "dns", title: "DNS", state: .warning, summary: "Slow", durationMS: 120)
        )
        .compared(with: baseline)

        #expect(current.baselineChanges == ["DNS: healthy to warning"])
    }

    @Test func timelineRetentionKeepsNewestBoundedSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkDiagnosticsTimelineStore(
            file: directory.appendingPathComponent("timeline.json"))
        for index in 0..<15 {
            _ = try await store.append(
                NetworkDiagnosticSnapshot(
                    createdAt: Date(timeIntervalSince1970: Double(index)), durationMS: 1,
                    state: .healthy, path: NetworkPathSummary(), checks: []),
                limit: 10)
        }
        let loaded = await store.load(limit: 100)

        #expect(loaded.count == 10)
        #expect(loaded.first?.createdAt == Date(timeIntervalSince1970: 14))
        #expect(loaded.last?.createdAt == Date(timeIntervalSince1970: 5))
    }

    @Test func engineExplainsLocalPathWithoutRemoteTargets() async {
        let engine = NetworkDiagnosticsEngine { executable, arguments, _ in
            switch (executable.lastPathComponent, arguments) {
            case ("route", _):
                NetworkCommandResult(
                    status: 0,
                    output: "gateway: 192.168.1.1\ninterface: en0\n")
            case ("ifconfig", _):
                NetworkCommandResult(status: 0, output: "inet 192.168.1.24 netmask 0xffffff00")
            case ("scutil", ["--dns"]):
                NetworkCommandResult(status: 0, output: "nameserver[0] : 1.1.1.1")
            case ("scutil", ["--proxy"]), ("scutil", ["--nc", "list"]):
                NetworkCommandResult(status: 0, output: "")
            case ("ping", _):
                NetworkCommandResult(
                    status: 0,
                    output:
                        "4 packets transmitted, 4 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 1.0/2.0/3.0/0.5 ms"
                )
            default:
                NetworkCommandResult(status: 1, output: "unexpected")
            }
        }
        let result = await engine.diagnose(configuration: NetworkDiagnosticsConfiguration())

        #expect(result.state == .healthy)
        #expect(result.path.interfaceName == "en0")
        #expect(result.path.gateway == "192.168.1.1")
        #expect(result.path.dnsServers == ["1.1.1.1"])
        #expect(result.checks.first { $0.id == "gateway" }?.packetLossPercent == 0)
        #expect(result.checks.first { $0.id == "dns-lookup" }?.state == .skipped)
    }

    @Test func processRunnerStopsAtTimeout() async {
        let started = Date()
        let result = await NetworkProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)

        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func completedFailedDiagnosisReturnsSnapshotAndSuccess() async {
        let result = await CLIProbe.run([
            "network", "diagnose", "--service", "127.0.0.1:1", "--timeout", "0.2", "--retries",
            "0", "--count", "1", "--json", "--no-history",
        ])

        #expect(result.code == 0)
        #expect(result.object?["state"] as? String == "failed")
    }

    private func snapshot(check: NetworkDiagnosticCheck) -> NetworkDiagnosticSnapshot {
        NetworkDiagnosticSnapshot(
            durationMS: 1, state: check.state, path: NetworkPathSummary(), checks: [check])
    }
}
