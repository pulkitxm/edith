import Darwin
import Foundation

struct HerdrSocketError: Error, Equatable {
    var message: String
}

final class HerdrSocketClient: @unchecked Sendable {
    static let boardSubscriptions: [[String: String]] = [
        ["type": "pane.created"],
        ["type": "pane.closed"],
        ["type": "pane.updated"],
        ["type": "pane.moved"],
        ["type": "pane.exited"],
        ["type": "pane.agent_detected"],
        ["type": "tab.created"],
        ["type": "tab.closed"],
        ["type": "tab.renamed"],
        ["type": "workspace.created"],
        ["type": "workspace.closed"],
        ["type": "workspace.updated"],
        ["type": "workspace.renamed"],
    ]

    static let relayScript = """
        import os,select,socket,sys
        c=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        c.connect(sys.argv[1])
        i=sys.stdin.buffer
        o=sys.stdout.buffer
        while True:
         r,_,_=select.select([i,c],[],[])
         if i in r:
          b=os.read(i.fileno(),65536)
          if not b:break
          c.sendall(b)
         if c in r:
          b=c.recv(65536)
          if not b:break
          os.write(o.fileno(),b)
        """

    private let writer: FileHandle
    private let reader: FileHandle
    private let teardown: () -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var eventWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var closed = false

    private init(writer: FileHandle, reader: FileHandle, teardown: @escaping () -> Void) {
        self.writer = writer
        self.reader = reader
        self.teardown = teardown
        startReading()
    }

    static func unix(path: String) throws -> HerdrSocketClient {
        let fd = try connectUnix(path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return HerdrSocketClient(writer: handle, reader: handle, teardown: {})
    }

    static func ssh(_ connection: SSHConnection, socketPath: String) throws -> HerdrSocketClient {
        let command =
            "export PATH=\"\(HerdrCollector.pathPrefix)\"; python3 -u -c \(ShellQuote.quote(relayScript)) \(ShellQuote.quote(socketPath))"
        let process = connection.streamProcess(command: command)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        return HerdrSocketClient(
            writer: stdinPipe.fileHandleForWriting,
            reader: stdoutPipe.fileHandleForReading,
            teardown: {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            })
    }

    var events: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            if closed {
                lock.unlock()
                continuation.finish()
                return
            }
            eventWaiters[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.eventWaiters[id] = nil
                self.lock.unlock()
            }
        }
    }

    func snapshot() async throws -> String {
        try await request(method: "session.snapshot", params: [:])
    }

    func subscribeBoard() async throws {
        let line = try await request(
            method: "events.subscribe",
            params: ["subscriptions": Self.boardSubscriptions])
        guard let object = HerdrListParser.firstJSON(in: line) as? [String: Any] else {
            throw HerdrSocketError(message: "herdr subscribe returned no JSON")
        }
        if let error = HerdrListParser.errorMessage(in: line) {
            throw HerdrSocketError(message: error)
        }
        let result = object["result"] as? [String: Any]
        let type = result?["type"] as? String
        if type != "subscription_started" {
            throw HerdrSocketError(message: "herdr subscribe was rejected")
        }
    }

    func close() {
        finish(HerdrSocketError(message: "herdr socket closed"))
    }

    deinit { close() }

    private func request(method: String, params: [String: Any]) async throws -> String {
        let id = UUID().uuidString
        let body: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        guard var line = String(data: data, encoding: .utf8) else {
            throw HerdrSocketError(message: "could not encode herdr request")
        }
        line += "\n"
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: HerdrSocketError(message: "herdr socket closed"))
                return
            }
            pending[id] = continuation
            lock.unlock()
            writer.write(Data(line.utf8))
            Task {
                try? await Task.sleep(for: .seconds(8))
                resume(
                    id: id, result: .failure(HerdrSocketError(message: "herdr socket timed out")))
            }
        }
    }

    private func startReading() {
        let reader = reader
        Task.detached { [weak self] in
            while let self {
                let data = reader.readData(ofLength: 64 * 1024)
                if data.isEmpty {
                    self.finish(HerdrSocketError(message: "herdr socket closed"))
                    return
                }
                self.ingest(data)
            }
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.firstRange(of: Data([10])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(..<range.upperBound)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
        }
        lock.unlock()
        for line in lines { handle(line) }
    }

    private func handle(_ line: String) {
        guard let object = HerdrListParser.firstJSON(in: line) as? [String: Any] else { return }
        if let id = object["id"] as? String, !id.isEmpty {
            if object["error"] != nil {
                resume(
                    id: id,
                    result: .failure(
                        HerdrSocketError(
                            message: HerdrListParser.errorMessage(in: line) ?? "herdr socket error")
                    )
                )
                return
            }
            if object["result"] != nil {
                resume(id: id, result: .success(line))
                return
            }
        }
        if HerdrListParser.isEventLine(line) {
            lock.lock()
            let waiters = Array(eventWaiters.values)
            lock.unlock()
            for waiter in waiters { waiter.yield(()) }
        }
    }

    private func resume(id: String, result: Result<String, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(_ error: HerdrSocketError) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let pending = pending
        self.pending = [:]
        let waiters = Array(eventWaiters.values)
        eventWaiters = [:]
        lock.unlock()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        for waiter in waiters { waiter.finish() }
        try? writer.close()
        if reader !== writer { try? reader.close() }
        teardown()
    }

    private static func connectUnix(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrSocketError(message: "could not open \(path)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < maxPath else {
            Darwin.close(fd)
            throw HerdrSocketError(message: "socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            if bytes.count < raw.count {
                raw[bytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            Darwin.close(fd)
            throw HerdrSocketError(message: "could not connect to \(path)")
        }
        return fd
    }
}

enum HerdrSocketDiscovery {
    static func local() -> [(name: String, path: String)] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr")
        return sockets(under: root)
    }

    static func remoteProbeCommand() -> String {
        "for p in \"$HOME/.config/herdr/herdr.sock\" \"$HOME/.config/herdr/sessions\"/*/herdr.sock; do if [ -S \"$p\" ]; then printf '%s\\n' \"$p\"; fi; done"
    }

    static func sockets(fromRemoteListing text: String) -> [(name: String, path: String)] {
        var seen = Set<String>()
        var sockets: [(name: String, path: String)] = []
        for line in text.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            sockets.append((name: sessionName(for: path), path: path))
        }
        return sockets
    }

    static func sessionName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "herdr" { return "default" }
        return parent.lastPathComponent
    }

    private static func sockets(under root: URL) -> [(name: String, path: String)] {
        let fm = FileManager.default
        var sockets: [(name: String, path: String)] = []
        let defaultPath = root.appendingPathComponent("herdr.sock")
        if fm.fileExists(atPath: defaultPath.path) {
            sockets.append((name: "default", path: defaultPath.path))
        }
        let sessions = root.appendingPathComponent("sessions")
        guard
            let names = try? fm.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: nil)
        else { return sockets }
        for folder in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let path = folder.appendingPathComponent("herdr.sock")
            if fm.fileExists(atPath: path.path) {
                sockets.append((name: folder.lastPathComponent, path: path.path))
            }
        }
        return sockets
    }
}
