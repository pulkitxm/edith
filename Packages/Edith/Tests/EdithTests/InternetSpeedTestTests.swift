import Foundation
import Testing

@testable import EdithKit

@Suite struct InternetSpeedTestTests {
    @Test func decodesNetworkQualityResult() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let measurement = try InternetSpeedTester.decode(
            """
            {"dl_throughput":142300000,"ul_throughput":110200000}
            """,
            measuredAt: date)
        #expect(measurement.downloadBitsPerSecond == 142_300_000)
        #expect(measurement.uploadBitsPerSecond == 110_200_000)
        #expect(measurement.measuredAt == date)
    }

    @Test func decodesCloudflareResult() throws {
        let measurement = try InternetSpeedTester.decode(
            """
            {"downloadBitsPerSecond":72000000,"uploadBitsPerSecond":160000000}
            """)
        #expect(measurement.downloadBitsPerSecond == 72_000_000)
        #expect(measurement.uploadBitsPerSecond == 160_000_000)
    }

    @Test func rejectsPassiveThroughputShape() {
        #expect(throws: InternetSpeedTestError.self) {
            try InternetSpeedTester.decode("{\"rxBps\":64000,\"txBps\":126000}")
        }
    }

    @Test func formatsInternetRatesAsBitsPerSecond() {
        #expect(InternetSpeedFormatter.string(800) == "800 bps")
        #expect(InternetSpeedFormatter.string(142_300_000) == "142 Mbps")
        #expect(InternetSpeedFormatter.string(72_000_000) == "72.0 Mbps")
        #expect(InternetSpeedFormatter.string(2_500_000_000) == "2.5 Gbps")
    }

    @Test func usesOnMachineTestCommands() {
        let mac = InternetSpeedTester.command(for: .darwin)
        let linux = InternetSpeedTester.command(for: .linux)
        let windows = InternetSpeedTester.command(for: .windows)
        #expect(mac.contains("networkQuality -c -M 10"))
        #expect(linux.contains("speed.cloudflare.com/__down?bytes=50000000"))
        #expect(linux.contains("speed.cloudflare.com/__up"))
        #expect(linux.contains("%{speed_download}"))
        #expect(linux.contains("%{speed_upload}"))
        #expect(linux.contains("-H 'Expect:'"))
        #expect(windows.contains("powershell.exe"))
    }
}

@Suite @MainActor struct MachineInternetSpeedTests {
    @Test func storesCapacityHistorySeparatelyFromLiveTraffic() {
        let session = MachineSession(
            machine: Machine(name: "This Mac", host: "localhost"), local: true)
        let measurement = InternetSpeedMeasurement(
            downloadBitsPerSecond: 142_300_000,
            uploadBitsPerSecond: 110_200_000,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
        session.apply(internetSpeed: measurement)
        #expect(session.internetSpeed == measurement)
        #expect(session.internetDownloadHistory.last == 142_300_000)
        #expect(session.internetUploadHistory.last == 110_200_000)
    }

    @Test func speedTestsAreObservedOnlyByVisibleOverviews() {
        let session = MachineSession(
            machine: Machine(name: "This Mac", host: "localhost"), local: true)
        session.beginInternetSpeedObservation()
        session.endInternetSpeedObservation()
        #expect(!session.isTestingInternetSpeed)
    }
}
