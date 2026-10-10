import EdithExtensionArchive
import EdithExtensionSupport
import Foundation

@MainActor @objc(EdithCLIFixtureRuntime)
final class CLIFixtureRuntime: NSObject {
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { operation, payload in
            switch operation {
            case "calendar.cli":
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                try request.validate()
                let failed = request.arguments == ["synthetic-error"]
                let output = try JSONSerialization.data(withJSONObject: request.arguments)
                return try JSONEncoder().encode(
                    ExtensionCLIReply(
                        stdout: failed ? "" : String(decoding: output, as: UTF8.self) + "\n",
                        stderr: failed ? "error: synthetic unavailable\n" : "",
                        exitCode: failed ? 4 : 0))
            case "echo": return payload
            case "archive":
                guard
                    let input = try JSONSerialization.jsonObject(with: payload)
                        as? [String: String],
                    let encoded = input["archive"], let archive = Data(base64Encoded: encoded),
                    let contents = try ArchiveFileReader.read(
                        named: "fixture.txt", from: archive, maximumBytes: 128),
                    let text = String(data: contents, encoding: .utf8)
                else { throw ExtensionPeerError.rejected("Invalid archive fixture.") }
                return try JSONSerialization.data(withJSONObject: ["text": text])
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
                "id": "keepAwake", "version": "VERSION", "hostABI": "edith-host-2",
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
