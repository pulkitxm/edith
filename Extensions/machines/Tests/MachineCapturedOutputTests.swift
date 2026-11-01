@testable import MachinesExtension
import EdithExtensionCommands
import Foundation
import Testing

@Suite struct MachineCapturedOutputTests {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var text: [String] = []
        private var data: [Data] = []
        var lines: [String] { lock.withLock { text } }
        var bytes: [Data] { lock.withLock { data } }
        func add(_ value: String) { lock.withLock { text.append(value) } }
        func add(_ value: Data) { lock.withLock { data.append(value) } }
    }

    private let hello =
        "@EDITH@{\"t\":\"hello\",\"v\":1,\"os\":\"macOS 26.0\",\"osID\":\"macos\","
        + "\"kernel\":\"25.0.0\",\"arch\":\"arm64\",\"host\":\"studio\","
        + "\"cpuModel\":\"Apple M4 Max\",\"cores\":16,\"memTotalKB\":16000000,"
        + "\"virtual\":false}"

    @Test func metricsOutputReachesTheCapturedSinkFromAPlainDispatchQueue() async {
        let collected = Collected()
        let sink = ExtensionCLIContext.$outputSink.withValue({ text, _ in collected.add(text) }) {
            MetricsSink(json: false, processes: 0, follow: true)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.ssh-line-stream.output").async { [hello] in
                sink.receive(hello)
                continuation.resume()
            }
        }
        #expect(collected.lines == ["studio  macOS 26.0  16 cores\n"])
    }

    @Test func rawDataPrefersTheRawSinkAndTextFallsBackToIt() {
        let collected = Collected()
        let output = CapturedCLIOutput(
            outputSink: nil, rawOutputSink: { data, _ in collected.add(data) })
        output.data(Data([1, 2]), error: false)
        output.line("done")
        #expect(collected.bytes == [Data([1, 2]), Data("done\n".utf8)])
    }

    @Test func textPrefersTheTextSink() {
        let collected = Collected()
        let output = CapturedCLIOutput(
            outputSink: { text, _ in collected.add(text) },
            rawOutputSink: { data, _ in collected.add(data) })
        output.text("a", error: true)
        #expect(collected.lines == ["a"])
        #expect(collected.bytes.isEmpty)
    }
}
