import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIByteOutputTests {
    @Test func discardedOutputAcceptsACharacterDevice() async throws {
        let descriptor = open("/dev/null", O_WRONLY)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        let output = try HostCLIByteOutput(descriptor: descriptor)
        try await output.send(Data("synthetic command result\n".utf8))
    }

    @Test func redirectedOutputPreservesBytesInARegularFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: url) }
        let output = try HostCLIByteOutput(descriptor: descriptor)
        let bytes = Data([0, 255, 10, 13, 120])
        try await output.send(bytes)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func rawOutputPreservesArbitraryBytesAndCancellationInterruptsBackpressure() async throws
    {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0], writeFD = fds[1]
        defer { Darwin.close(readFD); Darwin.close(writeFD) }
        let originalFlags = fcntl(writeFD, F_GETFL)
        let output = try HostCLIByteOutput(descriptor: writeFD)
        #expect(fcntl(writeFD, F_GETFL) == originalFlags)
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
