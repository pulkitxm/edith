import Foundation
import Testing

@testable import EdithCore

@Suite struct BackgroundTestingTests {
    @Test func modeIsHonoredOnlyForADevelopmentIdentity() {
        let development = "com.pulkit.edith.dev.bg-launch"
        #expect(
            BackgroundTesting.isHonored(
                environmentValue: "1", applicationIdentifier: development))
        #expect(
            BackgroundTesting.isHonored(
                environmentValue: nil,
                arguments: [BackgroundTesting.launchArgument],
                applicationIdentifier: development))
        #expect(
            !BackgroundTesting.isHonored(
                environmentValue: "1",
                arguments: [BackgroundTesting.launchArgument],
                applicationIdentifier: AppBuildIdentity.production))
        #expect(
            !BackgroundTesting.isHonored(
                environmentValue: nil, applicationIdentifier: development))
        #expect(
            !BackgroundTesting.isHonored(
                environmentValue: "0", applicationIdentifier: development))
        #expect(
            !BackgroundTesting.isHonored(
                environmentValue: "1", applicationIdentifier: "com.example.other"))
    }
}
