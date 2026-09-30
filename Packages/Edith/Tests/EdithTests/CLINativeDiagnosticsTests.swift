import Darwin
import Foundation
import Testing
@testable import EdithCLI

@Suite struct CLINativeDiagnosticsTests {
    @Test func nativeDiagnosticsCannotContaminateProtocolAndDescriptorIsRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("protocol.log")
        let native = root.appendingPathComponent("native.log")
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        do {
            let scope = try CLINativeDiagnostics(url: native, errorDescriptor: descriptor)
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(
                Data("native GPU diagnostic\n".utf8))
            scope.protocolHandle.write(Data("{\"event\":\"progress\"}\n".utf8))
        }
        FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(Data("restored\n".utf8))
        #expect(
            try String(contentsOf: output, encoding: .utf8)
                == "{\"event\":\"progress\"}\nrestored\n")
        #expect(try String(contentsOf: native, encoding: .utf8) == "native GPU diagnostic\n")
    }

    @Test func emptyNativeLogIsRemoved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = Darwin.open("/dev/null", O_WRONLY)
        defer { Darwin.close(descriptor) }
        do { _ = try CLINativeDiagnostics(url: url, errorDescriptor: descriptor) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
