import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithLaTeXExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: LaTeXWorker?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let worker = self?.worker else { throw ExtensionPeerError.unavailable }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        Task {
            await worker?.shutdown(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "latex", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                Self.hasEditorResources
            else { return ["ok": false] as NSDictionary }
            if worker == nil { worker = LaTeXWorker() }
            TextEditingCommands.install()
        case "view":
            guard let worker else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { LaTeXPage(model: worker.model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown(); worker?.model.editorControls.shutdown()
            worker = nil; TextEditingCommands.shutdown()
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private static var hasEditorResources: Bool {
        guard let editor = LaTeXEditorResources.url, let review = LaTeXEditorResources.reviewURL,
            let editorHTML = try? String(contentsOf: editor, encoding: .utf8),
            let reviewHTML = try? String(contentsOf: review, encoding: .utf8),
            let editorScript = try? Data(
                contentsOf: editor.deletingLastPathComponent().appendingPathComponent("editor.js")),
            let reviewScript = try? Data(
                contentsOf: review.deletingLastPathComponent().appendingPathComponent("review.js")),
            FileManager.default.fileExists(
                atPath: review.deletingLastPathComponent().appendingPathComponent("review.css").path
            )
        else { return false }
        return editorHTML.contains("editor.js") && reviewHTML.contains("review.js")
            && editorScript.count > 100_000 && reviewScript.count > 10_000
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
