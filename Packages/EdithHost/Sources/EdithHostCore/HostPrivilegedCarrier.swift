import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Security

@MainActor public final class HostPrivilegedCarrier: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: ExtensionPrivilegedService.identifier)
    private let team: String
    private var sessions: [UUID: HostPrivilegedSession] = [:]

    public init(approved: Bool) throws {
        guard approved, getuid() == 0, let team = ExtensionCodeSignature.teamIdentifier() else {
            throw MarketplaceError.invalidSignature
        }
        self.team = team
        super.init(); listener.delegate = self
    }

    public func run() { listener.resume(); RunLoop.current.run() }

    public nonisolated func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let box = HostPrivilegedConnection(connection)
        return MainActor.assumeIsolated {
            let connection = box.connection
            guard sessions.count < 8, let identifier = Bundle.main.bundleIdentifier else {
                return false
            }
            connection.setCodeSigningRequirement(
                "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            )
            let id = UUID()
            let admission = HostPrivilegedAdmission(
                root: URL(fileURLWithPath: "/Library/Application Support/Edith Extension Carrier")
            ) { [team] in try ExtensionCodeSignature.verify($0, teamIdentifier: team) }
            let session = HostPrivilegedSession(admission: admission) { [weak self] in
                self?.sessions[id] = nil
                guard self?.sessions.isEmpty == true else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(200));
                    if self?.sessions.isEmpty == true { exit(0) }
                }
            }
            sessions[id] = session
            connection.exportedInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
            connection.exportedObject = session
            connection.invalidationHandler = { Task { @MainActor in session.connectionLost() } }
            connection.interruptionHandler = connection.invalidationHandler
            connection.resume(); return true
        }
    }
}

@MainActor private final class HostPrivilegedSession: NSObject, ExtensionPrivilegedProtocol {
    private let admission: HostPrivilegedAdmission
    private let ended: @MainActor () -> Void
    private var worker: HostPrivilegedProcess?
    private var payload: URL?
    private var restoration: Task<Void, Never>?
    private var releasing = false

    init(admission: HostPrivilegedAdmission, ended: @escaping @MainActor () -> Void) {
        self.admission = admission; self.ended = ended
    }

    nonisolated func activate(
        _ source: String, owner: String, version: String,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        Task { @MainActor in
            do {
                guard self.worker == nil, !self.releasing else {
                    throw MarketplaceError.invalidBundle
                }
                let payload = try self.admission.admit(
                    source: URL(fileURLWithPath: source), owner: owner, version: version)
                self.payload = payload
                guard let executable = Bundle.main.executableURL else {
                    throw MarketplaceError.invalidBundle
                }
                let worker = HostPrivilegedProcess(
                    executable: executable, arguments: ["--extension-carrier-worker", payload.path])
                self.worker = worker
                try await worker.start()
                reply(nil)
            } catch { reply(error as NSError); self.finish() }
        }
    }

    nonisolated func invoke(
        _ command: String, payload: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task { @MainActor in
            guard !self.releasing, let worker = self.worker, !command.isEmpty,
                command.utf8.count <= 256, !command.utf8.contains(0), payload.count <= 32_768
            else { reply(nil, MarketplaceError.invalidBundle as NSError); return }
            do { reply(try await worker.invoke(command, payload: payload), nil) } catch {
                reply(nil, error as NSError)
            }
        }
    }

    nonisolated func release(reply: @escaping @Sendable (NSError?) -> Void) {
        Task { @MainActor in
            guard !self.releasing else {
                reply(
                    ExtensionPeerError.rejected("System settings are still being restored.")
                        as NSError);
                return
            }
            self.releasing = true
            do { try await self.prepare(); reply(nil); self.finish() } catch {
                self.releasing = false; reply(error as NSError)
            }
        }
    }

    func connectionLost() {
        guard restoration == nil else { return }
        releasing = true
        restoration = Task { [self] in
            while !Task.isCancelled {
                do { try await prepare(); finish(); return } catch {
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func prepare() async throws { try await worker?.stop() }

    private func finish() {
        worker = nil
        if let payload { try? admission.remove(payload); self.payload = nil }
        ended()
    }
}

private final class HostPrivilegedConnection: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
