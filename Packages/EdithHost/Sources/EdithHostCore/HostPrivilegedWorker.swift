import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor public final class HostPrivilegedWorker {
    private let object: NSObject
    private let image: UnsafeMutableRawPointer?
    private var frames = HostWorkerFrames()
    private var watcher: DispatchSourceProcess?
    private var ending = false
    private var admissionClosed = false
    private var invocation: Task<Void, Never>?
    private let suspension = HostWorkerPreparation()
    private let preparation = HostWorkerPreparation()
    private let quitPreparation = HostWorkerPreparation()
    private var restoration: Task<Void, Never>?

    public init(bundle: URL, fixture: Bool = false) throws {
        let development = Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.dev.") == true
        guard getuid() == 0 || fixture && development else {
            throw MarketplaceError.invalidSignature
        }
        if fixture {
            guard development,
                ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            else { throw MarketplaceError.invalidSignature }
            try ExtensionCodeSignature.verifyDevelopment(bundle)
        } else {
            guard let team = ExtensionCodeSignature.teamIdentifier(),
                bundle.deletingLastPathComponent().standardizedFileURL.path
                    == "/Library/Application Support/Edith Extension Carrier"
            else { throw MarketplaceError.invalidSignature }
            let admission = HostPrivilegedAdmission(root: bundle.deletingLastPathComponent()) {
                try ExtensionCodeSignature.verify($0, teamIdentifier: team)
            }
            try admission.validateProtected(bundle)
        }
        guard let loaded = Bundle(url: bundle), let executable = loaded.executableURL,
            let image = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL),
            let symbol = dlsym(image, "edith_extension_create")
        else { throw MarketplaceError.invalidBundle }
        self.image = image
        let factory = unsafeBitCast(
            symbol, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        guard let pointer = factory() else { throw MarketplaceError.invalidBundle }
        object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        guard object.responds(to: NSSelectorFromString("invoke:completion:")),
            object.responds(to: NSSelectorFromString("suspendCommandsWithCompletion:")),
            object.responds(to: NSSelectorFromString("prepareDisableWithCompletion:"))
        else { throw MarketplaceError.invalidBundle }
    }

    init(object: NSObject) {
        self.object = object
        image = nil
    }

    func prepareForStop(_ stop: HostPrivilegedStop) async throws {
        try await beginStop(stop, token: UUID()).value.get()
    }

    private func beginStop(_ stop: HostPrivilegedStop, token: UUID) throws
        -> Task<Result<Void, Error>, Never>
    {
        let retain = try stop.retainsState()
        guard !ending else { throw HostWorkerError.rejected }
        admissionClosed = true
        if !retain { return try beginRestore(token: token) }
        guard !preparation.isClosed else { throw HostWorkerError.rejected }
        return try quitPreparation.begin(token: token, operation: "applicationQuit") {
            try await self.suspend()
            guard !self.ending else { throw HostWorkerError.rejected }
            _ = try stop.retainsState()
        }
    }

    private func beginRestore(token: UUID = UUID()) throws -> Task<Result<Void, Error>, Never> {
        admissionClosed = true
        return try preparation.begin(token: token) {
            try await self.suspend()
            try await self.prepare()
        }
    }

    private func suspend() async throws {
        try await suspension.prepare {
            let selector = NSSelectorFromString("suspendCommandsWithCompletion:")
            guard self.object.responds(to: selector) else { throw MarketplaceError.invalidBundle }
            typealias Suspend =
                @convention(c) (AnyObject, Selector, @convention(block) () -> Void) -> Void
            let suspend = unsafeBitCast(self.object.method(for: selector), to: Suspend.self)
            await withCheckedContinuation { continuation in
                let completion: @convention(block) () -> Void = { continuation.resume() }
                suspend(self.object, selector, completion)
            }
            if let invocation = self.invocation { await invocation.value }
        }
    }

    public func run() {
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(1) }
        let watcher = DispatchSource.makeProcessSource(
            identifier: getppid(), eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.restoreAndExit() }
        }
        self.watcher = watcher; watcher.resume()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        RunLoop.current.run()
    }

    private func receive(_ data: Data) {
        guard !ending else { return }
        guard !data.isEmpty else { restoreAndExit(); return }
        do {
            for frame in try frames.append(data) {
                let request = try JSONDecoder().decode(HostPrivilegedRequest.self, from: frame)
                switch request.operation {
                case "start":
                    guard !admissionClosed else { throw HostWorkerError.rejected }
                    try send(request.token, data: Data())
                case "invoke":
                    guard !admissionClosed, invocation == nil,
                        let command = request.command, let payload = request.payload,
                        payload.count <= 32_768
                    else {
                        try send(
                            request.token,
                            error: "System settings are still being changed. Wait and try again.")
                        continue
                    }
                    invocation = Task { [self] in
                        defer { invocation = nil }
                        do {
                            try send(
                                request.token,
                                data: try await invoke(
                                    command, payload: payload, token: request.token))
                        } catch {
                            try? send(
                                request.token,
                                error: String(error.localizedDescription.prefix(1024)))
                        }
                    }
                case "prepareDisable", "stop":
                    let cleanup = Result {
                        if request.operation == "prepareDisable" {
                            return try beginRestore(token: request.token)
                        }
                        guard let stop = request.stop else { throw HostWorkerError.rejected }
                        return try beginStop(stop, token: request.token)
                    }
                    Task { [self] in
                        do {
                            try await cleanup.get().value.get()
                            try send(request.token, data: Data())
                            if request.operation == "stop" { exit(0) }
                        } catch {
                            try? send(
                                request.token,
                                error: String(error.localizedDescription.prefix(1024)))
                        }
                    }
                default:
                    try send(request.token, error: "The extension could not complete this action.")
                }
            }
        } catch { restoreAndExit() }
    }

    private func invoke(_ command: String, payload: Data, token: UUID) async throws -> Data {
        let selector = NSSelectorFromString("invoke:completion:")
        typealias Invoke =
            @convention(c) (
                AnyObject, Selector, NSDictionary, @convention(block) (NSData?, NSString?) -> Void
            ) -> Void
        let invoke = unsafeBitCast(object.method(for: selector), to: Invoke.self)
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (NSData?, NSString?) -> Void = { data, error in
                if let error {
                    continuation.resume(throwing: HostWorkerError.disableRejected(String(error)))
                } else if let data, data.length <= 32_768 {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(throwing: HostWorkerError.invalidResponse)
                }
            }
            invoke(
                object, selector,
                ["command": command, "payload": payload as NSData, "token": token.uuidString],
                completion)
        }
    }

    private func prepare() async throws {
        let selector = NSSelectorFromString("prepareDisableWithCompletion:")
        typealias Prepare =
            @convention(c) (AnyObject, Selector, @convention(block) (NSError?) -> Void) -> Void
        let prepare = unsafeBitCast(object.method(for: selector), to: Prepare.self)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let completion: @convention(block) (NSError?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            prepare(object, selector, completion)
        }
    }

    private func restoreAndExit() {
        guard restoration == nil else { return }
        ending = true
        FileHandle.standardInput.readabilityHandler = nil
        let cleanup = Result { try beginRestore() }
        restoration = Task { [self] in
            var pending = cleanup
            while true {
                do { try await pending.get().value.get(); exit(0) } catch {
                    try? await Task.sleep(for: .seconds(5))
                    pending = Result { try beginRestore() }
                }
            }
        }
    }

    private func send(_ token: UUID, data: Data? = nil, error: String? = nil) throws {
        try FileHandle.standardOutput.write(
            contentsOf: HostWorkerFrames.encode(
                HostPrivilegedResponse(token: token, data: data, error: error)))
    }
}
