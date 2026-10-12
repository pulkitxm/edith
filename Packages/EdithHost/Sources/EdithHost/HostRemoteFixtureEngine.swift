#if EDITH_CLI_FIXTURE
import AppKit
import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor
final class HostRemoteFixtureEngine {
    private let control: HostWorkerControl
    private var frames = HostWorkerFrames()
    private var configuration: HostWorkerConfiguration?
    private var server: ExtensionPeerServer?
    private var reads = 0
    private var holds = 0
    private var cancelled = 0
    private var record: URL?

    init() throws {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw HostWorkerError.rejected
        }
        control = HostWorkerControl(descriptor: descriptor)
    }

    func run() {
        _ = setsid()
        NSApplication.shared.setActivationPolicy(.prohibited)
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        NSApplication.shared.run()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { stop(); return }
        do {
            for bytes in try frames.append(data) {
                let request = try JSONDecoder().decode(HostWorkerRequest.self, from: bytes)
                switch request.operation {
                case "start":
                    guard configuration == nil, let next = request.configuration,
                        next.identifier == Bundle.main.bundleIdentifier,
                        next.extensionID == "sample"
                    else { throw HostWorkerError.rejected }
                    let identity = try next.identity()
                    configuration = next
                    record = identity.extensionDirectory("sample").appendingPathComponent(
                        "record.json")
                    try FileManager.default.createDirectory(
                        at: record!.deletingLastPathComponent(), withIntermediateDirectories: true)
                    writeRecord()
                    let endpoint = try ExtensionPeerEndpoint(
                        namespace: identity.identifier, owner: "sample",
                        directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
                    let server = ExtensionPeerServer(endpoint: endpoint) {
                        [weak self] _, operation, _ in
                        guard let self else { throw HostWorkerError.exited }
                        if operation == "sample.hold" {
                            holds += 1
                            writeRecord()
                            do { try await Task.sleep(for: .seconds(20)) } catch {
                                holds -= 1; cancelled += 1; writeRecord(); throw error
                            }
                            holds -= 1
                        } else if operation == "sample.read" {
                            reads += 1
                        } else {
                            throw HostWorkerError.rejected
                        }
                        writeRecord()
                        return try Data(contentsOf: record!)
                    }
                    try server.start()
                    self.server = server
                case "prepareDisable", "synchronize", "status": break
                case "stop":
                    try control.send(
                        HostWorkerResponse(
                            token: request.token, ok: true, version: configuration?.version))
                    stop()
                    return
                default: throw HostWorkerError.rejected
                }
                try control.send(
                    HostWorkerResponse(
                        token: request.token, ok: true, version: configuration?.version))
            }
        } catch { stop() }
    }

    private func writeRecord() {
        guard let record,
            let bytes = try? JSONSerialization.data(
                withJSONObject: [
                    "count": reads, "holds": holds, "cancelled": cancelled,
                    "enginePID": getpid(), "title": "Synthetic owned record",
                ], options: .sortedKeys)
        else { return }
        try? bytes.write(to: record, options: .atomic)
    }

    private func stop() {
        server?.shutdown()
        FileHandle.standardInput.readabilityHandler = nil
        NSApplication.shared.terminate(nil)
        exit(0)
    }
}
#endif
