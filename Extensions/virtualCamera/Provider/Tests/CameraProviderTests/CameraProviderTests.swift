import Foundation
import Testing
@testable import CameraProvider

@MainActor @Suite struct CameraProviderTests {
    @Test func syntheticProbeBuildsSupportedFormatsWithoutStartingAService() throws {
        let runtime = CameraProviderRuntime()
        let result = try #require(
            runtime.execute(["operation": "probe", "fixture": true]) as? NSDictionary)
        #expect(result["ok"] as? Bool == true)
        #expect(result["providerServiceStarted"] as? Bool == false)
        #expect(result["role"] as? String == "cameraProvider")
        #expect((runtime.execute(["operation": "stop"]) as? NSDictionary)?["ok"] as? Bool == true)
    }

    @Test func probeRequiresExplicitSyntheticAdmission() throws {
        let runtime = CameraProviderRuntime()
        #expect((runtime.execute(["operation": "probe"]) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "unknown"]) as? NSDictionary)?["ok"] as? Bool == false)
    }

    @Test func allAdvertisedProviderFormatsBuildExactVideoDescriptions() {
        for format in VirtualCameraFormat.supported {
            let value = CameraDeviceSource.streamFormat(format)
            #expect(value != nil)
            #expect(value?.minFrameDuration.value == 1)
            #expect(value?.minFrameDuration.timescale == Int32(format.frameRate))
        }
    }
}
