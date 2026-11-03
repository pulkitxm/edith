import Darwin
import EdithExtensionCore
import Foundation

private final class CrashFixtureBundle: NSObject {}

@MainActor
final class CrashFixtureService: ExtensionService {
    private let bundle = Bundle(for: CrashFixtureBundle.self)

    func start(_ context: ExtensionHostContext) -> Bool {
        guard let host = context.input["hostIdentifier"] as? String,
            host.hasPrefix("com.pulkit.edith.tests.crash-"),
            let root = ProcessInfo.processInfo.environment["EDITH_CRASH_PROOF_ROOT"],
            let directory = context.dataDirectory, directory.hasPrefix(root + "/")
        else { return false }
        if bundle.object(forInfoDictionaryKey: "FixtureCrashes") as? Bool == true { abort() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard command == "healthyProbe.echo" else { throw ExtensionPeerError.invalidRequest }
        return payload
    }
}

@_cdecl("edith_extension_configure_environment")
public func configureCrashFixture(_ pointer: UnsafeRawPointer) {
    let dictionary = Unmanaged<NSDictionary>.fromOpaque(pointer).takeUnretainedValue()
    let values = dictionary as! [String: String]
    let scope = ExtensionScope(
        environment: { values }, value: { values[$0] },
        defaults: { UserDefaults(suiteName: values["EDITH_SHARED_DEFAULTS_SUITE"]!)! },
        dataRoot: { URL(fileURLWithPath: values["EDITH_EXTENSION_DATA_ROOT"]!) })
    ExtensionScope.register(scope, image: #dsohandle)
}

@_cdecl("edith_extension_create")
public func createCrashFixture() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated {
        let bundle = Bundle(for: CrashFixtureBundle.self)
        let id = bundle.object(forInfoDictionaryKey: "FixtureID") as! String
        let runtime = ExtensionServiceRuntime(id: id, role: "app", bundle: bundle) { _ in
            CrashFixtureService()
        }
        return Unmanaged.passRetained(runtime).toOpaque()
    }
}
