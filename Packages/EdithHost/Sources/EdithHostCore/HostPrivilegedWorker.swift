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
    private var busy = false
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
            object.responds(to: NSSelectorFromString("prepareDisableWithCompletion:"))
        else { throw MarketplaceError.invalidBundle }
    }

    init(object: NSObject) {
        self.object = object
        image = nil
    }

    func prepareForStop(_ stop: HostPrivilegedStop) async throws {
        let retain = try stop.retainsState()
        if !retain { try await prepare() }
        guard !ending else { throw HostWorkerError.rejected }
        if retain { _ = try stop.retainsState() }
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
                if request.operation == "start" { try send(request.token, data: Data()); continue }
                guard !busy else {
                    try send(
                        request.token,
                        error: "System settings are still being changed. Wait and try again.");
                    continue
                }
                busy = true
                Task { [self] in
                    defer { busy = false }
                    do {
                        switch request.operation {
                        case "invoke":
                            guard let command = request.command, let payload = request.payload,
                                payload.count <= 32_768
                            else { throw HostWorkerError.rejected }
                            let data = try await invoke(command, payload: payload)
                            try send(request.token, data: data)
                        case "prepareDisable":
                            try await prepare(); try send(request.token, data: Data())
                        case "stop":
                            guard let stop = request.stop else { throw HostWorkerError.rejected }
                            try await prepareForStop(stop)
                            try send(request.token, data: Data()); exit(0)
                        default: throw HostWorkerError.rejected
                        }
                    } catch {
                        try? send(
                            request.token, error: String(error.localizedDescription.prefix(1024)))
                    }
                }
            }
        } catch { restoreAndExit() }
    }

    private func invoke(_ command: String, payload: Data) async throws -> Data {
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
                ["command": command, "payload": payload as NSData, "token": UUID().uuidString],
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
        restoration = Task { [self] in
            while true {
                if busy { try? await Task.sleep(for: .milliseconds(100)); continue }
                do { try await prepare(); exit(0) } catch {
                    try? await Task.sleep(for: .seconds(5))
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
