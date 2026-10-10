import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithExtensionCommands

extension ExtensionCLIExecutionTests {
    @Test func inputPreservesInitialAndLiveBytesThenEOF() async throws {
        let initial = Data((0..<32_771).map { UInt8(truncatingIfNeeded: $0) })
        let input = ExtensionCLIInput(initial: initial)
        let handle = inputHandle()
        let live = Data([0, 255, 192, 128, 10])
        let ack = try input.write(
            ExtensionCLIStreamWrite(handle: handle, sequence: 0, data: live, end: true))
        try ack.validate()
        #expect(ack.accepted && ack.nextSequence == 1)
        var received = Data()
        while let event = try await input.read() {
            guard case .bytes(let bytes) = event else { Issue.record("Unexpected resize"); break }
            #expect(bytes.count <= ExtensionCLIInput.maximumWriteBytes)
            received.append(bytes)
        }
        #expect(received == initial + live)
        #expect(try await input.read() == nil)
        #expect(throws: ExtensionPeerError.self) {
            try input.write(ExtensionCLIStreamWrite(handle: handle, sequence: 1, data: live))
        }
    }

    @Test func inputByteAndEventBoundsBackpressureWithoutDroppingOrAdvancing() async throws {
        let input = ExtensionCLIInput(initial: Data())
        let handle = inputHandle()
        let bytes = Data(repeating: 255, count: ExtensionCLIInput.maximumWriteBytes)
        for sequence in 0..<16 {
            #expect(
                try input.write(
                    ExtensionCLIStreamWrite(handle: handle, sequence: UInt64(sequence), data: bytes)
                ).accepted)
        }
        let retry = ExtensionCLIStreamWrite(handle: handle, sequence: 16, data: Data([0, 128]))
        let full = try input.write(retry)
        try full.validate()
        #expect(!full.accepted && full.nextSequence == 16)
        #expect(try await input.read() == .bytes(bytes))
        #expect(try input.write(retry).accepted)
        for _ in 1..<16 { #expect(try await input.read() == .bytes(bytes)) }
        #expect(try await input.read() == .bytes(retry.data))
        #expect(throws: ExtensionPeerError.self) { try input.write(retry) }
        #expect(throws: ExtensionPeerError.self) {
            try input.write(
                ExtensionCLIStreamWrite(handle: handle, sequence: 17, data: bytes + Data([0])))
        }
        #expect(throws: ExtensionPeerError.self) {
            try input.write(ExtensionCLIStreamWrite(handle: handle, sequence: 17, data: Data()))
        }
        for sequence in 17..<81 {
            #expect(
                try input.resize(
                    ExtensionCLIStreamResize(
                        handle: handle, sequence: UInt64(sequence), columns: 80, rows: 24)
                ).accepted)
        }
        let resize = ExtensionCLIStreamResize(handle: handle, sequence: 81, columns: 1, rows: 1_000)
        #expect(!((try input.resize(resize)).accepted))
        #expect(try await input.read() == .resize(columns: 80, rows: 24))
        #expect(try input.resize(resize).accepted)
        for _ in 0..<63 { #expect(try await input.read() == .resize(columns: 80, rows: 24)) }
        #expect(try await input.read() == .resize(columns: 1, rows: 1_000))
        for dimensions in [(0, 24), (80, 0), (1_001, 24), (80, 1_001), (Int.max, Int.min)] {
            #expect(throws: ExtensionPeerError.self) {
                try input.resize(
                    ExtensionCLIStreamResize(
                        handle: handle, sequence: 82, columns: dimensions.0, rows: dimensions.1))
            }
        }
        #expect(
            try input.write(
                ExtensionCLIStreamWrite(handle: handle, sequence: 82, data: Data(), end: true)
            ).accepted)
        #expect(try await input.read() == nil)
    }

    @Test func inputBlockedReadCancellationAndCloseActuallyResumeReaders() async throws {
        let input = ExtensionCLIInput(initial: Data())
        let first = Task { try await input.read() }
        await Task.yield()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task { try await input.read() }
        let bytes = Data([0, 255])
        #expect(
            try input.write(
                ExtensionCLIStreamWrite(handle: inputHandle(), sequence: 0, data: bytes)
            ).accepted)
        #expect(try await second.value == .bytes(bytes))
        let third = Task { try await input.read() }
        await Task.yield()
        input.close()
        await #expect(throws: CancellationError.self) { try await third.value }
        await #expect(throws: CancellationError.self) { try await input.read() }
        #expect(throws: ExtensionPeerError.self) {
            try input.write(
                ExtensionCLIStreamWrite(handle: inputHandle(), sequence: 1, data: bytes))
        }
    }

    @Test func inputAckRejectsMalformedCursors() throws {
        let handle = inputHandle()
        for values in [(UInt64(0), UInt64(2), true), (0, 1, false), (.max, .max, false)] {
            #expect(throws: ExtensionPeerError.self) {
                try ExtensionCLIStreamInputAck(
                    handle: handle, sequence: values.0, nextSequence: values.1, accepted: values.2
                ).validate()
            }
        }
    }

    private func inputHandle() -> ExtensionCLIStreamHandle {
        ExtensionCLIStreamHandle(owner: "synthetic", session: UUID(), token: UUID())
    }
}
