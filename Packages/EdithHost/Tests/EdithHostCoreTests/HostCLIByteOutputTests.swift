import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIByteOutputTests {
    @Test func rawOutputPreservesArbitraryBytesAndCancellationInterruptsBackpressure() async throws
    {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0], writeFD = fds[1]
        defer { Darwin.close(readFD); Darwin.close(writeFD) }
        let output = try HostCLIByteOutput(descriptor: writeFD)
        let bytes = Data([0, 255, 10, 13, 0, 120])
        try await output.send(bytes)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(readFD, &buffer, buffer.count)
        #expect(Data(buffer.prefix(max(0, count))) == bytes)
        let blocked = Task { try await output.send(Data(repeating: 120, count: 4 * 1024 * 1024)) }
        try await Task.sleep(for: .milliseconds(50))
        blocked.cancel()
        await #expect(throws: CancellationError.self) { try await blocked.value }
    }
}
