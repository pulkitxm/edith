import Foundation
import Testing
@testable import CameraDeployment

@Suite(.serialized) @MainActor struct CameraPrivilegedRuntimeTests {
    @Test func malformedAndUnsupportedCommandsReturnBoundedFailure() {
        let runtime = makeCameraPrivilegedRuntime()
        for request: NSDictionary in [
            [:], ["command": "unknown", "payload": Data("{}".utf8)],
            ["command": "installCarrier", "payload": Data(repeating: 0, count: 8193)],
            ["command": "providerStatus", "payload": Data("[]".utf8)],
            ["command": "installCarrier", "payload": Data("{\"source\":\"relative\"}".utf8)],
        ] {
            var completed = false
            runtime.invoke(request) { payload, error in
                completed = true
                #expect(payload == nil)
                #expect((error as String?)?.isEmpty == false)
                #expect((error as String?)?.utf8.count ?? 0 <= 4096)
            }
            #expect(completed)
        }
    }
    @Test func unusedInstallerReleasesWithoutChangingSystemResources() async {
        let runtime = makeCameraPrivilegedRuntime()
        var completed = false
        await withCheckedContinuation { continuation in
            runtime.prepareDisable { error in
                completed = true
                #expect(error == nil)
                continuation.resume()
            }
        }
        #expect(completed)
    }
}
