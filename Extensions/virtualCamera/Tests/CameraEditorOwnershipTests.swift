import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite(.serialized) @MainActor struct CameraEditorOwnershipTests {
    @Test func onlyValidatedUIConfigurationCanOwnTheEditorMonitor() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for stopUI in [true, false] {
            let runtime = makeCameraRuntime()
            #expect(!TextEditingCommands.isInstalled)
            let rejected =
                runtime.execute(["operation": "configureUI", "remoteUI": true])
                as? NSDictionary
            #expect(rejected?["ok"] as? Bool == false)
            #expect(!TextEditingCommands.isInstalled)
            let host = "com.pulkit.edith.tests.editor." + UUID().uuidString
            let suite = host + ".extensions.virtualCamera"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let context: NSDictionary = [
                "operation": "configureUI", "inProcess": true, "remoteUI": true,
                "hostIdentifier": host, "extensionID": "virtualCamera", "defaultsSuite": suite,
                "uiOnly": false, "presentationID": UUID().uuidString,
                "location": "main", "section": "virtualCamera", "engineClient": Bridge(),
            ]
            #expect((runtime.execute(context) as? NSDictionary)?["ok"] as? Bool == true)
            #expect(TextEditingCommands.isInstalled)
            if stopUI {
                let stopped = runtime.execute(["operation": "stopUI"]) as? NSDictionary
                #expect(stopped?["ok"] as? Bool == true)
                #expect(!TextEditingCommands.isInstalled)
            }
            await runtime.stop()
            #expect(!TextEditingCommands.isInstalled)
            #expect((runtime.execute(context) as? NSDictionary)?["ok"] as? Bool == false)
        }
    }

    private final class Bridge: NSObject {
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            completion(Data())
        }
        @objc func cancel(_ token: String) {}
    }
}
