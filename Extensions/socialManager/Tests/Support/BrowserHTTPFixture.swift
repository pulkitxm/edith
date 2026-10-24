import Foundation
import Network

final class BrowserHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "edith.browser.fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var boundPort: UInt16?
    private let pages: [String: String]

    init(pages: [String: String]) throws {
        self.pages = pages
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port, port.rawValue > 0
            else { return }
            self.lock.withLock { self.boundPort = port.rawValue }
        }
        listener.start(queue: queue)
    }

    func origin() async throws -> URL {
        for _ in 0..<200 {
            if let port = lock.withLock({ boundPort }) {
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, _, _ in
            guard let self, let data else { return }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = self.pages[path]
            let status = body == nil ? "404 Not Found" : "200 OK"
            let payload = body ?? "missing"
            let response =
                "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
