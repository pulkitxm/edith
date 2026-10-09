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
    private var object: NSObject?
    private var image: UnsafeMutableRawPointer?
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
                guard self.object == nil, !self.releasing else {
                    throw MarketplaceError.invalidBundle
                }
                let payload = try self.admission.admit(
                    source: URL(fileURLWithPath: source), owner: owner, version: version)
                self.payload = payload
                guard let bundle = Bundle(url: payload), let executable = bundle.executableURL,
                    let image = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL),
                    let symbol = dlsym(image, "edith_extension_create")
                else { throw MarketplaceError.invalidBundle }
                self.image = image
                let factory = unsafeBitCast(
                    symbol, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
                guard let pointer = factory() else { throw MarketplaceError.invalidBundle }
                let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
                guard object.responds(to: NSSelectorFromString("invoke:completion:")),
                    object.responds(to: NSSelectorFromString("prepareDisableWithCompletion:"))
                else { throw MarketplaceError.invalidBundle }
                self.object = object; reply(nil)
            } catch { reply(error as NSError); self.finish() }
        }
    }

    nonisolated func invoke(
        _ command: String, payload: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task { @MainActor in
            guard !self.releasing, let object = self.object, !command.isEmpty,
                command.utf8.count <= 256, !command.utf8.contains(0), payload.count <= 65_536
            else { reply(nil, MarketplaceError.invalidBundle as NSError); return }
            let selector = NSSelectorFromString("invoke:completion:")
            typealias Invoke =
                @convention(c) (
                    AnyObject, Selector, NSDictionary,
                    @convention(block) (NSData?, NSString?) -> Void
                ) -> Void
            let invoke = unsafeBitCast(object.method(for: selector), to: Invoke.self)
            let callback: @convention(block) (NSData?, NSString?) -> Void = { data, message in
                if let message {
                    reply(
                        nil,
                        NSError(
                            domain: "EdithExtensionPrivilege", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(message).prefix(1024).description
                            ]))
                } else if let data, data.length <= 65_536 {
                    reply(data as Data, nil)
                } else {
                    reply(nil, MarketplaceError.invalidBundle as NSError)
                }
            }
            invoke(
                object, selector,
                ["command": command, "payload": payload as NSData, "token": UUID().uuidString],
                callback)
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

    private func prepare() async throws {
        guard let object else { return }
        let selector = NSSelectorFromString("prepareDisableWithCompletion:")
        typealias Prepare =
            @convention(c) (AnyObject, Selector, @convention(block) (NSError?) -> Void) -> Void
        let function = unsafeBitCast(object.method(for: selector), to: Prepare.self)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let completion: @convention(block) (NSError?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            function(object, selector, completion)
        }
    }

    private func finish() {
        object = nil
        if let payload { try? admission.remove(payload); self.payload = nil }
        ended()
    }
}

private final class HostPrivilegedConnection: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
