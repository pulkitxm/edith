import EdithExtensionSupport
import Foundation

@MainActor @objc(EdithCLIFixtureRuntime)
final class CLIFixtureRuntime: NSObject {
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { operation, payload in
            switch operation {
            case "echo": return payload
            case "wait":
                let marker = ExtensionData.root.appendingPathComponent("wait.ready")
                try Data("ready".utf8).write(to: marker, options: .atomic)
                defer { try? FileManager.default.removeItem(at: marker) }
                try await Task.sleep(for: .seconds(30))
                return payload
            case "blockUI":
                let marker = ExtensionData.root.appendingPathComponent("ui.ready")
                try Data("ready".utf8).write(to: marker, options: .atomic)
                Thread.sleep(forTimeInterval: 1.5)
                try? FileManager.default.removeItem(at: marker)
                return Data("{\"finished\":true}".utf8)
            default: throw ExtensionPeerError.rejected("Unknown fixture operation.")
            }
        }
    }

    @objc(prepareToStopWithCompletion:) func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return [
                "id": "keepAwake", "version": "VERSION", "hostABI": "edith-host-1",
                "role": "helper",
            ] as NSDictionary
        case "start":
            do {
                try FileManager.default.createDirectory(
                    at: ExtensionData.root, withIntermediateDirectories: true)
                return ["ok": true] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "status": return ["ok": true] as NSDictionary
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
    }
}

@_cdecl("edith_extension_create")
public func createCLIFixture() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(CLIFixtureRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
