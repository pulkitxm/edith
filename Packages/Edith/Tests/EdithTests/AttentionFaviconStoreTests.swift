import AppKit
import Foundation
import ImageIO
import Network
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AttentionFaviconStoreTests {
    @Test func concurrentRequestsShareOneHTTPTransferAndReturnSmallImagesOverXPC() async throws {
        let server = try FaviconHTTPFixture(image: png())
        defer { server.stop() }
        let origin = try await server.origin()
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FaviconService(directory: directory)
        let runtime = AgentRuntime(build: "favicon", store: nil)
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentFaviconClient(client: listener.client())
        let url = origin.appendingPathComponent("icon")
        let values = try await withThrowingTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { try await client.data(for: url) } }
            var results: [Data?] = []
            for try await value in group { results.append(value) }
            return results
        }
        let data = try #require(values.first ?? nil)
        #expect(values.count == 8 && values.allSatisfy { $0 == data })
        #expect(server.count == 1)
        #expect(try await client.data(for: url) == data)
        #expect(server.count == 1)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 64)
        #expect(data.count <= FaviconService.maximumImageBytes)
        await runtime.shutdown()
    }

    @Test func oversizedUnknownLengthResponsesAndInvalidImagesAreBounded() async throws {
        let server = try FaviconHTTPFixture(image: png())
        defer { server.stop() }
        let origin = try await server.origin()
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FaviconService(directory: directory)
        await #expect(throws: AgentError.self) {
            try await service.data(for: origin.appendingPathComponent("large"))
        }
        #expect(try await service.data(for: origin.appendingPathComponent("invalid")) == nil)
        await #expect(throws: AgentError.self) {
            try await service.data(for: URL(fileURLWithPath: "/tmp/icon"))
        }
        await service.stop()
    }

    @Test func shutdownCancelsTheActiveTransferBeforeReturning() async throws {
        let server = try FaviconHTTPFixture(image: png())
        defer { server.stop() }
        let origin = try await server.origin()
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FaviconService(directory: directory)
        let pending = Task { try await service.data(for: origin.appendingPathComponent("stall")) }
        for _ in 0..<100 {
            if server.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.count == 1)
        let started = ContinuousClock.now
        await service.stop()
        #expect(started.duration(to: .now) < .seconds(2))
        do {
            _ = try await pending.value;
            Issue.record("Stopped transfer returned a successful image")
        } catch {}
        await #expect(throws: AgentError.self) { try await service.data(for: origin) }
    }

    private func cacheDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("favicon-fixture-\(UUID())")
    }

    private func png() throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 256, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class FaviconHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "edith.favicon.fixture")
    private let lock = NSLock()
    private let image: Data
    private var connections: [NWConnection] = []
    private var boundPort: UInt16?
    private var requests = 0
    var count: Int { lock.withLock { requests } }

    init(image: Data) throws {
        self.image = image
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port else { return }
            self.lock.withLock { self.boundPort = port.rawValue }
        }
        listener.start(queue: queue)
    }

    func origin() async throws -> URL {
        for _ in 0..<100 {
            if let port = lock.withLock({ boundPort }) {
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentError(.failed, "The favicon fixture did not start.")
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, _, _ in
            guard let self, let data else { return }
            self.lock.withLock { self.requests += 1 }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path == "/stall" { return }
            let body =
                path == "/large"
                ? Data(repeating: 7, count: (1 << 20) + 1)
                : path == "/invalid" ? Data("not an image".utf8) : self.image
            var response = Data(
                "HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: max-age=3600\r\n\r\n".utf8)
            response.append(body)
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                connection.send(
                    content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
