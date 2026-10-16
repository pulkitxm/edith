import Foundation
import Testing
@testable import BifrostExtension

@Suite(.serialized) @MainActor struct BifrostRuntimeTests {
    @Test func stoppedRuntimeCannotAllocateOrAcceptEngineWork() async {
        let runtime = ExtensionRuntime()
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        let suite = ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"] ?? ""
        let result =
            runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary
        #expect(result?["ok"] as? Bool == false)
        let status = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(status?["running"] as? Bool == false)
    }
}
