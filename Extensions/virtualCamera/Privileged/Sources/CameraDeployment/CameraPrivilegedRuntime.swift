import Darwin
import Foundation

@MainActor @objc(EdithCameraPrivilegedRuntime)
final class CameraPrivilegedRuntime: NSObject {
    private var ownsSession = false
    private var retirement: CameraMicrophoneRetirement?
    private var installer: CameraSealedInstallation?
    private var fixtureProviderActive = false
    private var fixtureMicrophoneActive = false
    private let files = FileManager.default
    private var bundle: Bundle { Bundle(for: CameraPrivilegedRuntime.self) }
    private var host: String { Bundle.main.bundleIdentifier ?? "" }
    private var carrier: URL {
        URL(fileURLWithPath: "/Applications/Edith Extensions/" + host + ".cameraCarrier.app")
    }
    private var fixture: Bool {
        getuid() != 0 && host.hasPrefix("com.pulkit.edith.tests.")
            && ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }
    private var journal: URL {
        bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(
            "camera-microphone-retirement.json")
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        do {
            guard let command = request["command"] as? String,
                let payload = request["payload"] as? Data, payload.count <= 8192,
                let values = try JSONSerialization.jsonObject(with: payload) as? [String: String]
            else { throw CocoaError(.coderReadCorrupt) }
            let result: [String: Any]
            switch command {
            case "installCarrier":
                guard values.count == 1, let source = values["source"], source.utf8.count <= 4096,
                    source.hasPrefix("/")
                else { throw CocoaError(.coderReadCorrupt) }
                if fixture {
                    guard
                        let root = ProcessInfo.processInfo.environment[
                            "EDITH_EXTENSION_FIXTURE_HOME"], source.hasPrefix(root + "/")
                    else { throw CocoaError(.fileReadNoPermission) }
                    result = ["path": source]
                } else {
                    let installed = try makeInstaller().installCarrier(
                        source: URL(fileURLWithPath: source), providerExited: try providerExited())
                    result = ["path": installed.path]
                }
            case "beginSession":
                guard values.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                ownsSession = true
                result = ["providerExited": try providerExited()]
            case "providerStatus":
                guard values.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                result = ["providerExited": try providerExited()]
            case "microphonePrepare":
                guard values.isEmpty, ownsSession else { throw CocoaError(.coderReadCorrupt) }
                if fixture {
                    fixtureMicrophoneActive = true
                } else {
                    _ = try makeInstaller().installMicrophone(carrier: carrier)
                }
                result = ["ok": true]
            case "microphoneDisable":
                guard values.isEmpty, ownsSession else { throw CocoaError(.coderReadCorrupt) }
                result = ["restartRequired": try retireMicrophone()]
            default: throw CocoaError(.coderReadCorrupt)
            }
            completion(
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    as NSData, nil)
        } catch { completion(nil, String(error.localizedDescription.prefix(1024)) as NSString) }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        do {
            if ownsSession {
                guard try providerExited() else {
                    throw failure(
                        "The camera provider is still running. Finish disabling it before releasing the carrier."
                    )
                }
                guard try !retireMicrophone() else {
                    throw failure(
                        "Restart macOS to finish removing the meeting microphone. Its loaded driver remains owned until restart."
                    )
                }
            }
            completion(nil)
        } catch { completion(error as NSError) }
    }

    private func makeInstaller() throws -> CameraSealedInstallation {
        guard getuid() == 0, host == "com.pulkit.edith" || host.hasPrefix("com.pulkit.edith.dev.")
        else { throw CocoaError(.fileWriteNoPermission) }
        if let installer { return installer }
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            let abi = bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
        else { throw CocoaError(.coderReadCorrupt) }
        let created = try CameraSealedInstallation(
            configuration: .init(hostIdentifier: host, version: version, hostABI: abi),
            privilegedBundle: bundle.bundleURL)
        installer = created; return created
    }

    private func providerExited() throws -> Bool {
        if fixture { return !fixtureProviderActive }
        _ = try makeInstaller()
        let team = try CameraSealedInstallation.signature(bundle.bundleURL).team
        return try CameraProviderProcessReader.exited(identifier: host + ".camera", team: team)
    }

    private func retireMicrophone() throws -> Bool {
        if fixture { fixtureMicrophoneActive = false; return false }
        if retirement == nil {
            let installer = try makeInstaller()
            let path = URL(
                fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/" + host + ".microphone.driver")
            let pending = try Self.readJournal(journal)
            let journal = self.journal
            retirement = CameraMicrophoneRetirement(
                boot: try Self.bootIdentifier(), pendingBoot: pending,
                installed: { FileManager.default.fileExists(atPath: path.path) },
                remove: { _ = try installer.removeMicrophone() },
                save: { try Self.writeJournal($0, to: journal) })
        }
        guard let retirement else { throw CocoaError(.fileReadUnknown) }
        return try retirement.retire()
    }

    private static func bootIdentifier() throws -> String {
        var value = [CChar](repeating: 0, count: 256)
        var size = value.count
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0, size > 1,
            size <= value.count
        else { throw CocoaError(.fileReadUnknown) }
        return String(cString: value)
    }

    private static func readJournal(_ url: URL) throws -> String? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard attributes.st_uid == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_mode & 0o077 == 0,
            attributes.st_size <= 256
        else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 257), data.count <= 256 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let value = try JSONDecoder().decode(String.self, from: data)
        guard value.utf8.count <= 128 else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    private static func writeJournal(_ value: String?, to url: URL) throws {
        if let value {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "EdithCameraPrivilege", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@_cdecl("edith_extension_create")
public func createCameraPrivilegedExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(CameraPrivilegedRuntime()).toOpaque())
        })
}
