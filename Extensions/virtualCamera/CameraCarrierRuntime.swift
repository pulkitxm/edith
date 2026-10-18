import Darwin
import Foundation
import Security

@MainActor final class CameraCarrierRuntime: NSObject {
    struct Environment {
        var admit: @MainActor () throws -> Void
        var lease: @MainActor (String, URL, String) throws -> any CameraCarrierLease
        var broker: @MainActor () -> any CameraSystemExtensionSubmitting
        var input: FileHandle
        var output: FileHandle
        var exited: @MainActor () -> Void
        var retryInterval: Duration = .seconds(5)
        static var live: Self {
            .init(
                admit: { try CameraCarrierCaller.admit() },
                lease: { CameraPrivilegedLease(host: $0, source: $1, version: $2) },
                broker: { CameraSystemExtensionBroker() }, input: .standardInput,
                output: .standardOutput, exited: { CFRunLoopStop(CFRunLoopGetMain()) })
        }
    }

    private var environment: Environment
    private var startup: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var session: CameraCarrierSession?
    private var lease: (any CameraCarrierLease)?
    private(set) var started = false
    private(set) var startupFailed = false
    init(environment: Environment = .live) { self.environment = environment }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: Self.self)
            return [
                "id": "virtualCamera", "role": "cameraCarrier",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "probe":
            return [
                "ok": input["fixture"] as? Bool == true, "payloadLoaded": true,
                "role": "cameraCarrier", "systemServiceStarted": false,
            ] as NSDictionary
        case "start":
            guard !started, let host = input["hostIdentifier"] as? String,
                let version = input["version"] as? String,
                let fixture = input["fixture"] as? Bool
            else { return ["ok": false] as NSDictionary }
            if fixture {
                guard host.hasPrefix("com.pulkit.edith.tests."),
                    Bundle.main.bundleIdentifier == host + ".cameraCarrier",
                    let root = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"],
                    Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(
                        URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/")
                else { return ["ok": false] as NSDictionary }
                let lease = CameraFixtureLease()
                environment = .init(
                    admit: {}, lease: { _, _, _ in lease },
                    broker: { CameraFixtureBroker(lease: lease) }, input: .standardInput,
                    output: .standardOutput, exited: { CFRunLoopStop(CFRunLoopGetMain()) })
            }
            do { try environment.admit() } catch { return ["ok": false] as NSDictionary }
            started = true
            let source = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/PlugIns/privileged.bundle")
            startup = Task { [weak self] in
                guard let self else { return }
                do {
                    let lease = try environment.lease(host, source, version)
                    self.lease = lease
                    let exited = try await lease.begin()
                    let microphoneOnly =
                        Bundle.main.object(forInfoDictionaryKey: "EdithCameraTransport") as? String
                        == "obs"
                    let controller = CameraSystemExtensionController(
                        identifier: host + ".camera",
                        broker: microphoneOnly
                            ? CameraMicrophoneOnlyBroker() : environment.broker(),
                        initiallyActive: microphoneOnly ? false : !exited,
                        providerExited: {
                            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                            repeat {
                                if try await lease.providerExited() { return true }
                                try await Task.sleep(for: .milliseconds(50))
                            } while ContinuousClock.now < deadline
                            return false
                        })
                    session = CameraCarrierSession(
                        controller: controller,
                        send: { [environment] in try environment.output.write(contentsOf: $0) },
                        microphoneOnly: microphoneOnly,
                        prepareMicrophone: { try await lease.prepareMicrophone() },
                        prepareDisableResources: { try await lease.retireMicrophone() },
                        releaseResources: { try await lease.release() },
                        exited: { [weak self, environment] in
                            self?.environment.input.readabilityHandler = nil
                            self?.retry?.cancel(); self?.retry = nil
                            environment.exited()
                        })
                    environment.input.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        Task { @MainActor in self?.session?.receive(data) }
                    }
                    retry = Task { [weak self, environment] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: environment.retryInterval) } catch {
                                return
                            }
                            self?.session?.retryDisconnectedCleanup()
                        }
                    }
                    if Task.isCancelled { session?.disconnect() }
                } catch {
                    startupFailed = true
                    if let lease {
                        retry = Task { [weak self] in
                            guard let self else { return }
                            while !Task.isCancelled {
                                do {
                                    try await lease.release()
                                    self.lease = nil
                                    environment.exited()
                                    return
                                } catch {
                                    do {
                                        try await Task.sleep(for: environment.retryInterval)
                                    } catch { return }
                                }
                            }
                        }
                    } else {
                        environment.exited()
                    }
                }
            }
        case "stop":
            startup?.cancel()
            session?.disconnect()
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@MainActor private final class CameraFixtureLease: CameraCarrierLease {
    var providerActive = false
    var microphoneActive = false
    func begin() async throws -> Bool { !providerActive }
    func providerExited() async throws -> Bool { !providerActive }
    func prepareMicrophone() async throws { microphoneActive = true }
    func retireMicrophone() async throws { microphoneActive = false }
    func release() async throws {
        guard !providerActive, !microphoneActive else { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor private final class CameraFixtureBroker: CameraSystemExtensionSubmitting {
    let lease: CameraFixtureLease
    init(lease: CameraFixtureLease) { self.lease = lease }
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        lease.providerActive = operation == .activate
        completion(.completed)
    }
}

enum CameraCarrierCaller {
    static func admit() throws {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String,
            host == "com.pulkit.edith" || host.hasPrefix("com.pulkit.edith.dev."),
            let team = try signingInformationSelf()[kSecCodeInfoTeamIdentifier as String]
                as? String,
            team.utf8.count == 10,
            team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
        else { throw CocoaError(.fileReadNoPermission) }
        var parent: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: getppid())] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess,
            let parent
        else { throw CocoaError(.fileReadNoPermission) }
        var requirement: SecRequirement?
        let text =
            "identifier \"\(host)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            SecCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess
        else { throw CocoaError(.fileReadNoPermission) }
    }
    private static func signingInformationSelf() throws -> [String: Any] {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw CocoaError(.fileReadNoPermission)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw CocoaError(.fileReadNoPermission)
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any]
        else { throw CocoaError(.fileReadNoPermission) }
        return values
    }
}

@MainActor private final class CameraMicrophoneOnlyBroker: CameraSystemExtensionSubmitting {
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        completion(
            .failed("Video uses OBS Virtual Camera. No camera provider is installed by Edith."))
    }
}
