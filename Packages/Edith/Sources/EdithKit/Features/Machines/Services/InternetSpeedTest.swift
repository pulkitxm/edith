import Foundation

public struct InternetSpeedMeasurement: Equatable, Sendable {
    public let downloadBitsPerSecond: Double
    public let uploadBitsPerSecond: Double
    public let measuredAt: Date

    public init(downloadBitsPerSecond: Double, uploadBitsPerSecond: Double, measuredAt: Date) {
        self.downloadBitsPerSecond = downloadBitsPerSecond
        self.uploadBitsPerSecond = uploadBitsPerSecond
        self.measuredAt = measuredAt
    }
}

public enum InternetSpeedFormatter {
    public static func string(_ bitsPerSecond: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var value = max(0, bitsPerSecond)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) bps" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}

public enum InternetSpeedTestError: LocalizedError {
    case unavailable(String)
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message.isEmpty ? "The internet speed test is unavailable." : message
        case .invalidResult:
            "The internet speed test returned an invalid result."
        }
    }
}

public enum InternetSpeedTester {
    public static func measureLocal() async throws -> InternetSpeedMeasurement {
        let result = await LocalMachineCommandExecution.run(
            executable: URL(fileURLWithPath: "/usr/bin/networkQuality"),
            arguments: ["-c", "-M", "10"], commandLabel: "networkQuality", timeout: 20)
        switch result {
        case let .success(output): return try decode(output)
        case let .failure(error): throw error
        }
    }

    public static func measureRemote(
        connection: SSHConnection, platform: RemoteMachinePlatform
    ) async throws -> InternetSpeedMeasurement {
        let command = command(for: platform)
        let result = try await connection.run(command, timeout: 45)
        guard result.succeeded else {
            throw InternetSpeedTestError.unavailable(result.stderrText)
        }
        return try decode(result.stdoutText)
    }

    static func decode(_ output: String, measuredAt: Date = Date()) throws
        -> InternetSpeedMeasurement
    {
        guard let data = output.data(using: .utf8) else {
            throw InternetSpeedTestError.invalidResult
        }
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(NetworkQualityResult.self, from: data),
            value.dlThroughput > 0, value.ulThroughput > 0
        {
            return InternetSpeedMeasurement(
                downloadBitsPerSecond: value.dlThroughput,
                uploadBitsPerSecond: value.ulThroughput,
                measuredAt: measuredAt)
        }
        if let value = try? decoder.decode(CloudflareResult.self, from: data),
            value.downloadBitsPerSecond > 0, value.uploadBitsPerSecond > 0
        {
            return InternetSpeedMeasurement(
                downloadBitsPerSecond: value.downloadBitsPerSecond,
                uploadBitsPerSecond: value.uploadBitsPerSecond,
                measuredAt: measuredAt)
        }
        throw InternetSpeedTestError.invalidResult
    }

    static func command(for platform: RemoteMachinePlatform) -> String {
        switch platform {
        case .darwin:
            unixCommand(
                prefix:
                    "if command -v networkQuality >/dev/null 2>&1; then networkQuality -c -M 10; exit; fi"
            )
        case .linux:
            unixCommand(prefix: "")
        case .windows:
            PowerShell.command(windowsScript)
        }
    }

    private static func unixCommand(prefix: String) -> String {
        """
        set -eu
        \(prefix)
        command -v curl >/dev/null 2>&1
        down=$(curl --http1.1 -fsS -o /dev/null --max-time 25 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=50000000')
        download=$(printf '%s\n' "$down" | awk '{ if ($1 <= 0) exit 1; printf "%.0f", $1*8 }')
        up=$(dd if=/dev/zero bs=1000000 count=50 2>/dev/null | curl --http1.1 -fsS -o /dev/null --max-time 25 -w '%{speed_upload}' -X POST -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @- 'https://speed.cloudflare.com/__up')
        upload=$(printf '%s\n' "$up" | awk '{ if ($1 <= 0) exit 1; printf "%.0f", $1*8 }')
        printf '{"downloadBitsPerSecond":%s,"uploadBitsPerSecond":%s}\n' "$download" "$upload"
        """
    }

    private static let windowsScript = """
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $download = $client.GetByteArrayAsync('https://speed.cloudflare.com/__down?bytes=50000000').GetAwaiter().GetResult()
        $timer.Stop()
        $downloadRate = [Math]::Round($download.LongLength * 8 / $timer.Elapsed.TotalSeconds)
        $payload = New-Object byte[] 50000000
        $content = [Net.Http.ByteArrayContent]::new($payload)
        $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $timer.Restart()
        $response = $client.PostAsync('https://speed.cloudflare.com/__up', $content).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $timer.Stop()
        $uploadRate = [Math]::Round($payload.LongLength * 8 / $timer.Elapsed.TotalSeconds)
        [ordered]@{ downloadBitsPerSecond = $downloadRate; uploadBitsPerSecond = $uploadRate } | ConvertTo-Json -Compress
        """

    private struct NetworkQualityResult: Decodable {
        let dlThroughput: Double
        let ulThroughput: Double

        enum CodingKeys: String, CodingKey {
            case dlThroughput = "dl_throughput"
            case ulThroughput = "ul_throughput"
        }
    }

    private struct CloudflareResult: Decodable {
        let downloadBitsPerSecond: Double
        let uploadBitsPerSecond: Double
    }
}
